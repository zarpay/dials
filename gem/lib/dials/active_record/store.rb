# frozen_string_literal: true

module Dials
  module Stores
    # The production store: three ActiveRecord-backed tables (see
    # Dials::ActiveRecord::Setting / Variation / Change). Implements the same
    # interface as Stores::Memory; every mutation runs in a transaction with
    # its change-log row, so the version can never run ahead of or behind the
    # data it stamps.
    class ActiveRecordStore
      Setting = Dials::ActiveRecord::Setting
      Variation = Dials::ActiveRecord::Variation
      Change = Dials::ActiveRecord::Change
      Lock = Dials::ActiveRecord::Lock

      # Sentinel for "this row could not be decoded; skip it".
      SKIP = Object.new

      # Database races a write can lose and safely re-run once: two processes
      # creating the same parent row (RecordNotUnique), a clear destroying a
      # parent while a concurrent set inserts a variation (InvalidForeignKey),
      # and adapter-reported deadlocks / serialization failures
      # (TransactionRollbackError covers both).
      RETRYABLE = [
        ::ActiveRecord::RecordNotUnique,
        ::ActiveRecord::InvalidForeignKey,
        ::ActiveRecord::TransactionRollbackError
      ].freeze

      def state
        # Version first: if a write lands between these reads, the snapshot
        # carries an older version than its data, and the next probe sees the
        # version move and rebuilds — stale in the safe direction only.
        current_version = version

        globals = {}
        Setting.where.not(value: nil).pluck(:key, :value).each do |key, raw|
          value = decode_row(raw, "dials(#{key})")
          globals[key.to_sym] = value unless value.equal?(SKIP)
        end

        variations = {}
        Variation.joins(:setting)
                 .pluck("#{Setting.table_name}.key", "#{Variation.table_name}.scope", "#{Variation.table_name}.value")
                 .each do |key, scope, raw|
          value = decode_row(raw, "dial_variations(#{key}, #{scope})")
          next if value.equal?(SKIP) || !valid_scope_string?(key, scope)

          (variations[key.to_sym] ||= {})[scope] = value
        end

        { globals: globals, variations: variations, version: current_version }
      end

      # The change log is append-only, so its row count moves on every
      # committed write and only ever grows. Count alone would be enough;
      # max id is included as a belt against direct log surgery. Max id
      # alone would NOT be enough: transaction A can claim id 10, B claim
      # and commit id 11, and only then A commits — MAX(id) never moves for
      # a process that already saw 11, so A's write would stay invisible
      # until the next unrelated write. Count catches it (N → N+1).
      def version
        [Change.count, Change.maximum(:id) || 0]
      end

      # True when the current thread's connection is inside an open
      # transaction (typically an application transaction wrapping a
      # Dials.set). The facade uses this to keep uncommitted dial state out
      # of the shared cache.
      def transaction_open?
        pool = Setting.connection_pool
        return false unless pool.active_connection?

        connection = pool.respond_to?(:lease_connection) ? pool.lease_connection : pool.connection
        connection.transaction_open?
      end

      # Runs the block after the current application transaction commits
      # (immediately when no transaction is open). Discarded on rollback.
      # The AR >= 7.2 floor enforced at require time guarantees the hook
      # exists.
      def after_commit(&)
        if transaction_open?
          ::ActiveRecord.after_all_transactions_commit(&)
        else
          yield
        end
      end

      def set_global(key, value, actor, expected_version: nil)
        transaction_with_retry do
          assert_version!(expected_version)
          setting = Setting.find_or_initialize_by(key: key.to_s)
          old = setting.value.nil? ? nil : decode(setting.value)
          setting.update!(value: encode(value))
          record(key, nil, "set", old, value, actor)
          old
        end
      end

      def clear_global(key, actor, expected_version: nil)
        transaction_with_retry do
          assert_version!(expected_version)
          setting = Setting.find_by(key: key.to_s)
          next false if setting.nil? || setting.value.nil?

          old = decode(setting.value)
          if setting.variations.exists?
            setting.update!(value: nil)
          else
            setting.destroy!
          end
          record(key, nil, "clear", old, nil, actor)
          true
        end
      end

      def set_variation(key, canonical_scope, value, actor, expected_version: nil)
        transaction_with_retry do
          assert_version!(expected_version)
          setting = Setting.find_or_create_by!(key: key.to_s)
          variation = setting.variations.find_or_initialize_by(scope: canonical_scope)
          old = variation.persisted? ? decode(variation.value) : nil
          variation.update!(value: encode(value))
          record(key, canonical_scope, "set", old, value, actor)
          old
        end
      end

      def clear_variation(key, canonical_scope, actor, expected_version: nil)
        transaction_with_retry do
          assert_version!(expected_version)
          setting = Setting.find_by(key: key.to_s)
          variation = setting&.variations&.find_by(scope: canonical_scope)
          next false if variation.nil?

          old = decode(variation.value)
          variation.destroy!
          # A parent holding neither a global override nor any variation is
          # meaningless; remove it so "no overrides" and "no rows" stay
          # synonyms.
          setting.destroy! if setting.value.nil? && !setting.variations.exists?
          record(key, canonical_scope, "clear", old, nil, actor)
          true
        end
      end

      def changes(key: nil, limit: 50)
        relation = Change.order(id: :desc).limit(limit)
        relation = relation.where(key: key.to_s) if key
        relation.filter_map do |row|
          ChangeRecord.new(
            key: row.key.to_sym,
            scope: row.scope && Scope.parse(row.scope),
            action: row.action,
            old_value: row.old_value.nil? ? nil : decode(row.old_value),
            new_value: row.new_value.nil? ? nil : decode(row.new_value),
            actor_type: row.actor_type,
            actor_id: row.actor_id,
            actor_label: row.actor_label,
            created_at: row.created_at
          )
        rescue StandardError => e
          # Same quarantine rule as state: one corrupt row (written around
          # the gem) must not take down the whole history listing — whether
          # the value fails to parse or the scope parses to a non-object.
          quarantine("dial_changes(id #{row.id})", "row does not decode (#{e.class})")
          nil
        end
      end

      private

      # The compare half of compare-and-swap, atomic with the write: it runs
      # INSIDE the write's transaction, and every version-checked writer
      # first takes a row lock on the single dial_locks anchor row — so of
      # two concurrent writes carrying the same expected version, exactly one
      # commits; the other blocks on the lock, then re-reads a version that
      # has moved, and raises. StaleWrite is deliberately not in RETRYABLE:
      # a retried CAS would recompute against the new version and succeed,
      # silently defeating the mechanism. On raise the transaction rolls
      # back — nothing applied, nothing logged.
      def assert_version!(expected)
        return if expected.nil?

        lock_anchor!
        return if expected == StoreVersion.token(version)

        raise StaleWrite,
              "the store has moved past version #{expected} — re-read (Dials.overview) and retry deliberately"
      end

      # SELECT ... FOR UPDATE on the anchor row the install migration seeds.
      # Created on demand for databases migrated before the row existed; the
      # create race (RecordNotUnique) is RETRYABLE, and the retry finds the
      # row. SQLite ignores FOR UPDATE but serializes writers at the database
      # level, which gives the same guarantee.
      def lock_anchor!
        Lock.lock.find_by(id: Dials::ActiveRecord::Lock::ANCHOR_ID) ||
          Lock.create!(id: Dials::ActiveRecord::Lock::ANCHOR_ID)
      end

      def record(key, canonical_scope, action, old_value, new_value, actor)
        Change.create!(
          key: key.to_s,
          scope: canonical_scope,
          action: action,
          old_value: old_value.nil? ? nil : encode(old_value),
          new_value: new_value.nil? ? nil : encode(new_value),
          actor_type: actor[:actor_type],
          actor_id: actor[:actor_id],
          actor_label: actor[:actor_label]
        )
      end

      # One retry, and only when we are NOT inside an application
      # transaction: after a failure there, the outer transaction is in an
      # aborted state (PostgreSQL) and re-running statements would fail
      # differently — the error must propagate to whoever owns that
      # transaction.
      def transaction_with_retry(&)
        attempts = 0
        begin
          Setting.transaction(&)
        rescue *RETRYABLE
          attempts += 1
          retry if attempts == 1 && !transaction_open?
          raise
        end
      end

      def encode(value)
        JSON.generate(value)
      end

      # Values round-trip through JSON, so a :json dial's hash keys come back
      # as strings — the same value a JSON API would hand you. Scalar types
      # (boolean, integer, float, string) round-trip exactly.
      def decode(raw)
        JSON.parse(raw)
      end

      # Rows written around the gem (console surgery, bad imports) must not
      # take down every dial read in the process: a row that does not decode
      # to a legal stored value is skipped with a warning, and every other
      # dial keeps resolving.
      def decode_row(raw, where)
        value = decode(raw)
        if value.nil?
          quarantine(where, "stored value is JSON null")
          return SKIP
        end

        value
      rescue JSON::ParserError
        quarantine(where, "stored value is not valid JSON")
        SKIP
      end

      def valid_scope_string?(key, scope)
        parsed = JSON.parse(scope)
        return true if parsed.is_a?(Hash) && !parsed.empty?

        quarantine("dial_variations(#{key})", "scope #{scope.inspect} is not a non-empty JSON object")
        false
      rescue JSON::ParserError
        quarantine("dial_variations(#{key})", "scope #{scope.inspect} is not valid JSON")
        false
      end

      def quarantine(where, reason)
        warn "[dials] skipping corrupt row in #{where}: #{reason} (fix or delete the row; it was not written through Dials.set)"
        nil
      end
    end
  end
end

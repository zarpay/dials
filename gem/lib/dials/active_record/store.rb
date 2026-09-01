# frozen_string_literal: true

module Dials
  module Stores
    # The production store: three ActiveRecord-backed tables — dials (one row
    # per stored override; the global is the override at the empty scope,
    # stored as Scope::GLOBAL), dial_changes (append-only log and version
    # counter), and dial_locks (the single-row write-serialization anchor).
    # Implements the same interface as Stores::Memory; every mutation runs in
    # a transaction with its change-log row, so the version can never run
    # ahead of or behind the data it stamps.
    #
    # Every write takes SELECT ... FOR UPDATE on the anchor row first, fully
    # serializing gem writes across processes. That is what makes
    # expected_version: compare-and-swap sound against every concurrent gem
    # write (not just other CAS writes) and gives the change log's old/new
    # values a true total order. Operators turn dials at human rates; the
    # serialization costs nothing that matters.
    class ActiveRecordStore
      Override = Dials::ActiveRecord::Override
      Change = Dials::ActiveRecord::Change
      Lock = Dials::ActiveRecord::Lock

      # Sentinel for "this row could not be decoded; skip it".
      SKIP = Object.new

      # Database races a write can lose and safely re-run once: two processes
      # creating the anchor row (RecordNotUnique — also covers hypothetical
      # override-insert races from writes made around the gem), and
      # adapter-reported deadlocks / serialization failures
      # (TransactionRollbackError covers both). StaleWrite is deliberately
      # NOT here — a retried CAS would recompute against the new version and
      # silently defeat the mechanism.
      RETRYABLE = [
        ::ActiveRecord::RecordNotUnique,
        ::ActiveRecord::TransactionRollbackError
      ].freeze

      def state
        # Version first: if a write lands between these reads, the snapshot
        # carries an older version than its data, and the next probe sees the
        # version move and rebuilds — stale in the safe direction only. The
        # data itself is ONE query over one table, so a snapshot can no
        # longer mix pre-write globals with post-write variations.
        current_version = version

        globals = {}
        variations = {}
        Override.pluck(:key, :scope, :value).each do |key, scope, raw|
          value = decode_row(raw, "dials(#{key}, #{scope})")
          next if value.equal?(SKIP)

          if scope == Scope::GLOBAL
            globals[key.to_sym] = value
          elsif valid_scope_string?(key, scope)
            (variations[key.to_sym] ||= {})[scope] = value
          end
        end

        { globals: globals, variations: variations, version: current_version }
      end

      # The change log is append-only, so its row count moves on every
      # committed write and only ever grows. Count alone would be enough;
      # max id is included as a belt against direct log surgery. Max id
      # alone would NOT be enough: transaction A can claim id 10, B claim
      # and commit id 11, and only then A commits — MAX(id) never moves for
      # a process that already saw 11, so A's write would stay invisible
      # until the next unrelated write. Count catches it (N → N+1). Both
      # aggregates come from ONE statement so they describe one committed
      # state, never two.
      def version
        count, max = Change.pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(MAX(id), 0)"))
        [count, max]
      end

      # True when the current thread's connection is inside an open
      # transaction (typically an application transaction wrapping a dial
      # write). The facade uses this to keep uncommitted dial state out of
      # the shared cache.
      def transaction_open?
        pool = Override.connection_pool
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
        write(expected_version) { set_override(key, Scope::GLOBAL, nil, value, actor) }
      end

      def clear_global(key, actor, expected_version: nil)
        write(expected_version) { clear_override(key, Scope::GLOBAL, nil, actor) }
      end

      def set_variation(key, canonical_scope, value, actor, expected_version: nil)
        write(expected_version) { set_override(key, canonical_scope, canonical_scope, value, actor) }
      end

      def clear_variation(key, canonical_scope, actor, expected_version: nil)
        write(expected_version) { clear_override(key, canonical_scope, canonical_scope, actor) }
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

      # Every mutation: one transaction, the anchor lock, the optional
      # version comparison, then the block. Locking BEFORE comparing is what
      # makes CAS atomic with the write: a concurrent writer (CAS or not)
      # either committed before we took the lock — so the comparison sees its
      # change — or blocks until we commit.
      def write(expected_version)
        transaction_with_retry do
          lock_anchor!
          assert_version!(expected_version)
          yield
        end
      end

      # The stored override's scope is always a canonical string (the global
      # is Scope::GLOBAL); the change log's scope stays nil for globals
      # (history's stable encoding), which is why both travel separately.
      def set_override(key, stored_scope, logged_scope, value, actor)
        override = Override.find_or_initialize_by(key: key.to_s, scope: stored_scope)
        old = override.persisted? ? decode(override.value) : nil
        override.update!(value: encode(value))
        record(key, logged_scope, "set", old, value, actor)
        old
      end

      # Clearing removes the row — "no override" and "no row" are synonyms
      # at every layer, with no anchor rows to garbage-collect. Clearing what
      # is not there is a no-op and logs nothing (but the version comparison,
      # if requested, already ran: a stale no-op is still stale).
      # Named for the action, not the boolean (it mirrors the public clear,
      # whose return is "did an override exist").
      def clear_override(key, stored_scope, logged_scope, actor) # rubocop:disable Naming/PredicateMethod
        override = Override.find_by(key: key.to_s, scope: stored_scope)
        return false if override.nil?

        old = decode(override.value)
        override.destroy!
        record(key, logged_scope, "clear", old, nil, actor)
        true
      end

      # The compare half of compare-and-swap. Runs after the anchor lock, so
      # of two concurrent writes carrying the same expected version, exactly
      # one commits; the other blocks on the lock, then re-reads a version
      # that has moved, and raises StaleWrite — transaction rolled back,
      # nothing applied, nothing logged.
      def assert_version!(expected)
        return if expected.nil?
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
          Override.transaction(&)
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

      # For non-global rows only — the global's "{}" was matched before this
      # runs, so an empty object here is corrupt (likely a hand-written row).
      def valid_scope_string?(key, scope)
        parsed = JSON.parse(scope)
        return true if parsed.is_a?(Hash) && !parsed.empty?

        quarantine("dials(#{key})", "scope #{scope.inspect} is not a non-empty JSON object")
        false
      rescue JSON::ParserError
        quarantine("dials(#{key})", "scope #{scope.inspect} is not valid JSON")
        false
      end

      def quarantine(where, reason)
        warn "[dials] skipping corrupt row in #{where}: #{reason} (fix or delete the row; it was not written through the Dials API)"
        nil
      end
    end
  end
end

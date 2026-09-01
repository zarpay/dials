# frozen_string_literal: true

module Dials
  module Stores
    # The production store: two ActiveRecord-backed tables — dials (one row
    # per stored override; the global is the override at the empty scope,
    # stored as Scope::GLOBAL) and dial_changes (append-only log and version
    # counter). Implements the same interface as Stores::Memory; every
    # mutation runs in a transaction with its change-log row, so the version
    # can never run ahead of or behind the data it stamps.
    #
    # Concurrency control is per-row optimistic locking, with no lock table
    # and no advisory locks: every row carries a `version` stamp (the id of
    # the change-log entry that last wrote it), and mutations are guarded
    # statements — `UPDATE/DELETE ... WHERE version = <what I read>` — plus
    # the UNIQUE(key, scope) index for inserts ("still absent" is the
    # compare, the insert is the swap). The database's own row semantics make
    # each write atomic against EVERY concurrent write, conditional or not:
    # an interleaving writer changes the row version (or creates/deletes the
    # row), the guarded statement matches zero rows, and the transaction —
    # change-log row included — rolls back untouched.
    class ActiveRecordStore
      Override = Dials::ActiveRecord::Override
      Change = Dials::ActiveRecord::Change

      # Sentinel for "this row could not be decoded; skip it".
      SKIP = Object.new

      # Database races a write can lose and safely re-run once: two processes
      # inserting the same override (RecordNotUnique — the re-run sees the
      # row and proceeds as an update or a StaleWrite), and adapter-reported
      # deadlocks / serialization failures (TransactionRollbackError covers
      # both). StaleWrite is deliberately NOT here — a retried CAS would
      # recompute against the new version and silently defeat the mechanism.
      RETRYABLE = [
        ::ActiveRecord::RecordNotUnique,
        ::ActiveRecord::TransactionRollbackError
      ].freeze

      # A guarded statement matched zero rows: an unconditional write lost a
      # race and the whole transaction should re-run with fresh reads.
      # Internal — surfaced as Dials::WriteConflict when retries run out.
      class Conflict < StandardError
      end

      # Attempts per write: the first, plus retries for lost races. Operator
      # write rates make even the second attempt rare.
      WRITE_ATTEMPTS = 3

      def state
        # Version first: if a write lands between these reads, the snapshot
        # carries an older version than its data, and the next probe sees the
        # version move and rebuilds — stale in the safe direction only. The
        # data itself is ONE query over one table, so a snapshot can never
        # mix pre-write globals with post-write variations.
        current_version = version

        globals = {}
        variations = {}
        row_versions = {}
        Override.pluck(:key, :scope, :value, :version).each do |key, scope, raw, row_version|
          value = decode_row(raw, "dials(#{key}, #{scope})")
          next if value.equal?(SKIP)

          if scope == Scope::GLOBAL
            globals[key.to_sym] = value
          elsif valid_scope_string?(key, scope)
            (variations[key.to_sym] ||= {})[scope] = value
          else
            next
          end
          (row_versions[key.to_sym] ||= {})[scope] = row_version
        end

        { globals: globals, variations: variations, version: current_version, row_versions: row_versions }
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

      # A single override row's version stamp; 0 when no row exists (the
      # StoreVersion::ABSENT state). The facade reads this after a CAS write
      # to hand the caller the token for chaining.
      def override_version(key, canonical_scope)
        Override.where(key: key.to_s, scope: canonical_scope).pick(:version) || 0
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
        write { set_override(key, Scope::GLOBAL, nil, value, actor, expected_version) }
      end

      def clear_global(key, actor, expected_version: nil)
        write { clear_override(key, Scope::GLOBAL, nil, actor, expected_version) }
      end

      def set_variation(key, canonical_scope, value, actor, expected_version: nil)
        write { set_override(key, canonical_scope, canonical_scope, value, actor, expected_version) }
      end

      def clear_variation(key, canonical_scope, actor, expected_version: nil)
        write { clear_override(key, canonical_scope, canonical_scope, actor, expected_version) }
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

      # One write: read the row, compare (when asked), append the change-log
      # entry, then the guarded mutation — all in one transaction. The
      # change-log row is created BEFORE the guarded statement so its id can
      # stamp the row's new version; a guard that matches zero rows raises,
      # rolling the log entry back with everything else.
      def set_override(key, stored_scope, logged_scope, value, actor, expected)
        row = Override.find_by(key: key.to_s, scope: stored_scope)
        current = row&.version || 0
        assert_version!(expected, current)

        old = row && decode(row.value)
        change = record(key, logged_scope, "set", old, value, actor)

        if row
          updated = Override.where(id: row.id, version: current)
                            .update_all(value: encode(value), version: change.id, updated_at: Time.now.utc)
          raise(expected ? StaleWrite : Conflict, "override changed mid-write") if updated.zero?
        else
          # UNIQUE(key, scope) is the compare for inserts: a concurrent
          # insert raises RecordNotUnique, and the re-run sees the row.
          Override.create!(key: key.to_s, scope: stored_scope, value: encode(value), version: change.id)
        end

        old
      end

      # Clearing removes the row — "no override" and "no row" are synonyms
      # at every layer. Clearing what is not there is a no-op and logs
      # nothing; with expected_version: it first proves the caller's picture
      # (a page showing an override that no longer exists is stale).
      # rubocop:disable-next Naming/PredicateMethod
      def clear_override(key, stored_scope, logged_scope, actor, expected)
        row = Override.find_by(key: key.to_s, scope: stored_scope)
        current = row&.version || 0
        assert_version!(expected, current)

        return false if row.nil?

        old = decode(row.value)
        record(key, logged_scope, "clear", old, nil, actor)
        deleted = Override.where(id: row.id, version: current).delete_all
        raise(expected ? StaleWrite : Conflict, "override changed mid-write") if deleted.zero?

        true
      end

      def assert_version!(expected, current)
        return if expected.nil? || expected == StoreVersion.token(current)

        raise StaleWrite,
              "the override has changed since version #{expected} was read — " \
              "re-read (Dials.overview) and retry deliberately"
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

      # Retries re-run the WHOLE transaction with fresh reads — but only when
      # we are NOT inside an application transaction: after a database error
      # there, the outer transaction is in an aborted state (PostgreSQL) and
      # re-running statements would fail differently — the error must
      # propagate to whoever owns that transaction. A Conflict that survives
      # every attempt surfaces as WriteConflict (unconditional writes racing
      # each other — essentially never at operator rates).
      def write(&)
        attempts = 0
        begin
          Override.transaction(&)
        rescue *RETRYABLE, Conflict => e
          attempts += 1
          retry if attempts < WRITE_ATTEMPTS && !transaction_open?
          raise WriteConflict, "concurrent writes kept racing this override — safe to retry" if e.is_a?(Conflict)

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

# frozen_string_literal: true

module Dials
  module Stores
    # The production store: ONE ActiveRecord-backed, append-only table (see
    # Dials::ActiveRecord::Entry). Every write INSERTs a row; the newest row
    # per (key, scope) stream is the current override, and the same rows are
    # the attributed history and the cache's version counter. The global
    # override is the stream at Scope::GLOBAL (the canonical empty scope).
    # Implements the same interface as Stores::Memory.
    #
    # Concurrency control is the stream sequence: each row claims its
    # stream's next `seq` under UNIQUE(key, scope, seq), so of two concurrent
    # writes the database rejects one — atomic, with no lock table, no
    # advisory locks, and no guarded updates. A rejected unconditional write
    # re-runs with fresh reads; a rejected compare-and-swap re-runs, sees the
    # interleaved write, and raises StaleWrite. Rows are immutable and seq
    # only grows, so a stale-write token (the live row's seq) can never be
    # revisited by a later delete-and-recreate.
    class ActiveRecordStore
      Entry = Dials::ActiveRecord::Entry

      # Sentinel for "this row could not be decoded; skip it".
      SKIP = Object.new

      # Database races a write can lose and safely re-run: two writers
      # claiming the same seq (RecordNotUnique — the re-run reads the new
      # newest row), and adapter-reported deadlocks / serialization failures
      # (TransactionRollbackError covers both). StaleWrite is deliberately
      # NOT here — a retried CAS would recompute against the new state and
      # silently defeat the mechanism (the re-run raises it AFTER re-reading,
      # which is the correct outcome, not a retry of the comparison).
      RETRYABLE = [
        ::ActiveRecord::RecordNotUnique,
        ::ActiveRecord::TransactionRollbackError
      ].freeze

      # Attempts per write: the first, plus retries for lost seq claims.
      # Operator write rates make even the second attempt rare.
      WRITE_ATTEMPTS = 3

      def state
        # Version first: if a write lands between these reads, the snapshot
        # carries an older version than its data, and the next probe sees the
        # version move and rebuilds — stale in the safe direction only.
        current_version = version

        globals = {}
        scoped = {}
        row_versions = {}
        newest_rows.each do |row|
          case row.action
          when "clear"
            # Tombstones carry no value but DO carry the stream's stale-write
            # stamp — an "absent" token must go stale when set/clear activity
            # happened since it was read.
            (row_versions[row.key.to_sym] ||= {})[row.scope] = row.seq
            next
          when "set"
            nil # fall through to the value path
          else
            quarantine("dials(#{row.key}, #{row.scope})", "unknown action #{row.action.inspect}")
            next
          end

          value = decode_row(row.value, "dials(#{row.key}, #{row.scope})")
          next if value.equal?(SKIP)

          if row.scope == Scope::GLOBAL
            globals[row.key.to_sym] = value
          elsif valid_scope_string?(row.key, row.scope)
            (scoped[row.key.to_sym] ||= {})[row.scope] = value
          else
            next
          end
          (row_versions[row.key.to_sym] ||= {})[row.scope] = row.seq
        end

        { globals: globals, scoped_overrides: scoped, version: current_version, row_versions: row_versions }
      end

      # The table is append-only, so its row count moves on every committed
      # write and only ever grows. Count alone would be enough; max id is
      # included as a belt against direct table surgery. Max id alone would
      # NOT be enough: transaction A can claim id 10, B claim and commit id
      # 11, and only then A commits — MAX(id) never moves for a process that
      # already saw 11, so A's write would stay invisible until the next
      # unrelated write. Count catches it (N → N+1). Both aggregates come
      # from ONE statement so they describe one committed state, never two.
      def version
        count, max = Entry.pick(Arel.sql("COUNT(*)"), Arel.sql("COALESCE(MAX(id), 0)"))
        [count, max]
      end

      # The stale-write stamp of one override stream: the seq of its newest
      # row, LIVE OR TOMBSTONE — a cleared override keeps its clear row's
      # stamp, so an absent → set → clear cycle can never make an old
      # "absent" token current again (no ABA). Only a stream with no rows at
      # all is 0, the StoreVersion::ABSENT state.
      def override_version(key, canonical_scope)
        newest(key, canonical_scope)&.seq || 0
      end

      # True when the current thread's connection is inside an open
      # transaction (typically an application transaction wrapping a dial
      # write). The facade uses this to keep uncommitted dial state out of
      # the shared cache.
      def transaction_open?
        pool = Entry.connection_pool
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

      # The two mutations. `canonical_scope` is always a canonical string —
      # Scope::GLOBAL for the global override. Both return [result, seq]:
      # the usual result (previous value / did-anything-exist) plus the
      # stream's seq after the write, so the facade can mint the caller's
      # next token from the row it KNOWS was written — never from a second
      # read that a concurrent writer could slip in front of.
      def set_override(key, canonical_scope, value, actor, expected_version: nil)
        write(expected_version) do
          row = newest(key, canonical_scope)
          assert_version!(expected_version, row&.seq || 0)

          old = live?(row) ? decode(row.value) : nil
          seq = (row&.seq || 0) + 1
          append(key, canonical_scope, seq, "set", encode(value), actor)
          [old, seq]
        end
      end

      # Clearing appends a "clear" row, ending the stream's live override —
      # resolution falls to the next layer, and the history of how it got
      # there is preserved. Clearing what is not live is a no-op and appends
      # nothing (but the version comparison, if requested, already ran: a
      # stale no-op is still stale).
      def clear_override(key, canonical_scope, actor, expected_version: nil)
        write(expected_version) do
          row = newest(key, canonical_scope)
          assert_version!(expected_version, row&.seq || 0)
          next [false, row&.seq || 0] unless live?(row)

          seq = row.seq + 1
          append(key, canonical_scope, seq, "clear", nil, actor)
          [true, seq]
        end
      end

      def changes(key: nil, limit: 50)
        relation = Entry.order(id: :desc).limit(limit)
        relation = relation.where(key: key.to_s) if key
        rows = relation.to_a
        previous = predecessors_of(rows)

        rows.filter_map do |row|
          pred = previous[[row.key, row.scope, row.seq - 1]]
          ChangeRecord.new(
            key: row.key.to_sym,
            scope: row.scope == Scope::GLOBAL ? nil : Scope.parse(row.scope),
            action: row.action,
            old_value: pred && pred.action == "set" ? decode(pred.value) : nil,
            new_value: row.action == "set" ? decode(row.value) : nil,
            actor_type: row.actor_type,
            actor_id: row.actor_id,
            actor_label: row.actor_label,
            created_at: row.created_at
          )
        rescue StandardError => e
          # Same quarantine rule as state: one corrupt row (written around
          # the gem) must not take down the whole history listing.
          quarantine("dials(id #{row.id})", "row does not decode (#{e.class})")
          nil
        end
      end

      private

      # The newest row of one (key, scope) stream, live or not.
      def newest(key, canonical_scope)
        Entry.where(key: key.to_s, scope: canonical_scope).order(seq: :desc).first
      end

      def live?(row)
        !row.nil? && row.action == "set"
      end

      # Every stream's newest row, in one query. The correlated NOT EXISTS
      # is portable across PostgreSQL, MySQL, and SQLite (no window
      # functions) and walks the (key, scope, seq) index.
      def newest_rows
        Entry.where(<<~SQL.squish)
          NOT EXISTS (
            SELECT 1 FROM #{Entry.table_name} newer
            WHERE newer.key = #{Entry.table_name}.key
              AND newer.scope = #{Entry.table_name}.scope
              AND newer.seq > #{Entry.table_name}.seq
          )
        SQL
      end

      def append(key, canonical_scope, seq, action, encoded_value, actor)
        Entry.create!(
          key: key.to_s,
          scope: canonical_scope,
          seq: seq,
          action: action,
          value: encoded_value,
          actor_type: actor[:actor_type],
          actor_id: actor[:actor_id],
          actor_label: actor[:actor_label]
        )
      end

      # The predecessor row (seq - 1) for each listed change, fetched with
      # one exact predicate per stream (no Cartesian over-fetch across
      # unrelated keys/scopes) — old_value is derived from history itself,
      # so history cannot disagree with what was actually replaced.
      def predecessors_of(rows)
        wanted = rows.filter_map { |r| [r.key, r.scope, r.seq - 1] if r.seq > 1 }
        return {} if wanted.empty?

        wanted.group_by { |k, s, _| [k, s] }
              .map { |(k, s), triples| Entry.where(key: k, scope: s, seq: triples.map(&:last)) }
              .reduce(:or)
              .index_by { |r| [r.key, r.scope, r.seq] }
      end

      # The compare half of compare-and-swap; `current` is the stream's
      # newest seq, tombstones included (ABSENT strictly means "this stream
      # was never written"). The comparison itself is a read; atomicity
      # comes from the seq claim under UNIQUE(key, scope, seq) — a writer
      # that interleaves between this check and our INSERT takes our slot,
      # our INSERT raises RecordNotUnique, and write() converts that
      # directly to StaleWrite for CAS callers (a lost claim PROVES an
      # interleaver). Nothing applied, nothing logged.
      def assert_version!(expected, current)
        return if expected.nil? || expected == StoreVersion.token(current)

        raise StaleWrite,
              "the override has changed since version #{expected} was read — " \
              "re-read (Dials.overview) and retry deliberately"
      end

      # A CAS write that loses its seq claim is STALE by definition — the
      # lost claim proves a concurrent write landed after the version was
      # read — so RecordNotUnique converts straight to StaleWrite, with no
      # retry and no re-read (correct even inside an aborted outer
      # transaction, where re-reading is impossible). Unconditional writes
      # re-run the WHOLE transaction with fresh reads — but only when we are
      # NOT inside an application transaction: after a database error there,
      # the outer transaction is in an aborted state (PostgreSQL) and
      # re-running statements would fail differently — the error must
      # propagate to whoever owns that transaction. A seq claim that loses
      # every attempt surfaces as WriteConflict (unconditional writes racing
      # each other — essentially never at operator rates).
      def write(expected_version, &)
        attempts = 0
        begin
          Entry.transaction(&)
        rescue ::ActiveRecord::RecordNotUnique
          if expected_version
            raise StaleWrite,
                  "a concurrent write landed after version #{expected_version} was read — re-read (Dials.overview) and retry deliberately"
          end

          attempts += 1
          retry if attempts < WRITE_ATTEMPTS && !transaction_open?
          raise WriteConflict, "concurrent writes kept racing this override — safe to retry"
        rescue ::ActiveRecord::TransactionRollbackError
          attempts += 1
          retry if attempts < WRITE_ATTEMPTS && !transaction_open?
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
      rescue TypeError, JSON::ParserError
        quarantine(where, "stored value is not valid JSON")
        SKIP
      end

      # For non-global streams only — the global's "{}" was matched before
      # this runs, so an empty object here is corrupt (a hand-written row).
      # Canonical exactness is required, not just shape: a noncanonical
      # spelling ({"b":1,"a":2}, spaces, non-string values) would be a
      # stream the resolver can never match against a canonicalized request.
      def valid_scope_string?(key, scope)
        parsed = JSON.parse(scope)
        unless parsed.is_a?(Hash) && !parsed.empty?
          quarantine("dials(#{key})", "scope #{scope.inspect} is not a non-empty JSON object")
          return false
        end
        return true if Scope.canonical(Scope.parse(scope)) == scope

        quarantine("dials(#{key})", "scope #{scope.inspect} is not canonical")
        false
      rescue JSON::ParserError, InvalidScope
        quarantine("dials(#{key})", "scope #{scope.inspect} is not a valid canonical scope")
        false
      end

      def quarantine(where, reason)
        warn "[dials] skipping corrupt row in #{where}: #{reason} (fix or delete the row; it was not written through the Dials API)"
        nil
      end
    end
  end
end

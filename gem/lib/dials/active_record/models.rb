# frozen_string_literal: true

module Dials
  module ActiveRecord
    # The three gem-owned tables. Values are stored as JSON text (not jsonb)
    # so the schema is portable across PostgreSQL, MySQL, and SQLite; nothing
    # ever queries inside a value or a scope — reads go through the
    # in-process cache, so the database is durable storage, not a query
    # surface.
    #
    # These models are internal plumbing for Stores::ActiveRecordStore.
    # Application code reads and writes through the Dials facade, which is
    # where validation, attribution, locking, and cache busting live.
    # Writing to these models directly bypasses all of it.

    # One stored override — the `dials` table holds nothing else. A global
    # override is simply the override at the empty scope, stored under the
    # canonical encoding "{}"; a variation is the override at a non-empty
    # canonical scope. `value` is NOT NULL: "no override" is "no row", at
    # every layer — no anchor rows, no NULL-vs-false ambiguity to guard.
    # Identity is the natural key (key, scope), unique.
    #
    # NOTE: uniqueness is textual, under the column's collation. Scope
    # strings are canonical (sorted keys, string values) so gem writes can
    # never collide cosmetically; on MySQL, a case-insensitive default
    # collation additionally treats scopes differing only by case ("KE" vs
    # "ke") as one row — don't declare dimension options that differ only by
    # case, or give the table a binary collation.
    class Override < ::ActiveRecord::Base
      self.table_name = "dials"

      validates :key, :scope, presence: true
      validates :scope, uniqueness: { scope: :key }
      validates :value, presence: { message: "cannot be SQL NULL" }, unless: -> { value == "false" }
    end

    # A single-row anchor EVERY write locks (SELECT ... FOR UPDATE) inside
    # its transaction. Serializing all gem writes across processes is what
    # makes expected_version: compare-and-swap sound against every concurrent
    # gem write (not just other CAS writes) and gives the change log a true
    # total order; operator write rates make the serialization cost
    # irrelevant. One row, no data — it exists to be locked.
    class Lock < ::ActiveRecord::Base
      self.table_name = "dial_locks"

      ANCHOR_ID = 1
    end

    # Append-only attribution log; also the store's version counter (its max
    # id moves on every write, which is what the cache staleness probe
    # watches). Never given an updated_at — rows are facts, not state.
    # `scope` here stays NULL for global changes — history keeps one stable
    # encoding for readers regardless of how storage spells the empty scope.
    class Change < ::ActiveRecord::Base
      self.table_name = "dial_changes"

      validates :key, presence: true
      validates :action, presence: true, inclusion: { in: %w[set clear] }

      # App-level append-only: a persisted change refuses update and destroy
      # through ActiveRecord. (Raw SQL and delete_all can still bypass this —
      # rows are history AND the cache's version counter, so don't.)
      def readonly?
        persisted?
      end
    end
  end
end

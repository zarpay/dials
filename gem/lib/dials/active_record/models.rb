# frozen_string_literal: true

module Dials
  module ActiveRecord
    # The one gem-owned table. Values are stored as JSON text (not jsonb)
    # so the schema is portable across PostgreSQL, MySQL, and SQLite; nothing
    # ever queries inside a value or a scope — reads go through the
    # in-process cache, so the database is durable storage, not a query
    # surface.
    #
    # This model is internal plumbing for Stores::ActiveRecordStore.
    # Application code reads and writes through the Dials facade, which is
    # where validation, attribution, and cache busting live. Writing to it
    # directly bypasses all of that.

    # One row per WRITE — the table is append-only, so the change log IS the
    # state. The newest row per (key, scope) stream is the current override:
    # action "set" carries the value; action "clear" says the override is
    # gone (resolution falls to the next layer). A global override is simply
    # the stream at the empty scope, stored under the canonical encoding
    # "{}". History cannot disagree with state because they are the same
    # rows, and an override's previous value is literally its previous row.
    #
    # `seq` numbers each stream's rows 1, 2, 3...; UNIQUE(key, scope, seq)
    # is what makes writes atomic without locks or guarded updates: every
    # writer claims the stream's next slot, and of two concurrent claims the
    # database rejects one. Rows are immutable and seq only grows, so a
    # stale-write token (the live row's seq) can never be revisited.
    #
    # NOTE: uniqueness is textual, under the column's collation. Scope
    # strings are canonical (sorted keys, string values) so gem writes can
    # never collide cosmetically; on MySQL, a case-insensitive default
    # collation additionally treats scopes differing only by case ("KE" vs
    # "ke") as one stream — don't declare dimension enums that differ only
    # by case, or give the table a binary collation.
    class Entry < ::ActiveRecord::Base
      # Prefixable via Dials.configure { |c| c.table_name_prefix = "zar_" }
      # for apps where "dials" collides with an existing table (see
      # Config#table_name_prefix).
      DEFAULT_TABLE_NAME = "dials"
      self.table_name = DEFAULT_TABLE_NAME

      validates :key, :scope, :seq, presence: true
      validates :action, presence: true, inclusion: { in: %w[set clear] }
      validates :value, presence: true, if: -> { action == "set" }

      # App-level append-only: a persisted row refuses update and destroy
      # through ActiveRecord. (Raw SQL and delete_all can still bypass this —
      # rows are state, history, AND the cache's version counter, so don't.)
      def readonly?
        persisted?
      end
    end
  end
end

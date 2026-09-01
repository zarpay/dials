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
    # Application code reads and writes through Dials.get / Dials.set /
    # Dials.clear, which is where validation, attribution, and cache busting
    # live. Writing to these models directly bypasses all three.

    # A dial's stored global override. A row exists once anything about the
    # dial has been overridden; `value` NULL means "no global override —
    # inherit the code default" (needed because variations hang off this row
    # by foreign key and must survive a cleared global).
    class Setting < ::ActiveRecord::Base
      self.table_name = "dials"

      has_many :variations,
               class_name: "Dials::ActiveRecord::Variation",
               foreign_key: "dial_id",
               inverse_of: :setting,
               dependent: :delete_all

      validates :key, presence: true, uniqueness: true
    end

    # A per-scope override. The NOT NULL foreign key is the invariant carried
    # over from the pattern's origin: no variation without a parent row, no
    # sentinel scopes, ever.
    class Variation < ::ActiveRecord::Base
      self.table_name = "dial_variations"

      belongs_to :setting,
                 class_name: "Dials::ActiveRecord::Setting",
                 foreign_key: "dial_id",
                 inverse_of: :variations

      validates :scope, presence: true, uniqueness: { scope: :dial_id }
      validates :value, presence: { message: "cannot be SQL NULL" }, unless: -> { value == "false" }
    end

    # A single-row anchor for compare-and-swap writes. A write carrying
    # expected_version: takes SELECT ... FOR UPDATE on this row inside its
    # transaction, serializing the version comparison with the change-log
    # append across processes. One row, no data — it exists to be locked.
    class Lock < ::ActiveRecord::Base
      self.table_name = "dial_locks"

      ANCHOR_ID = 1
    end

    # Append-only attribution log; also the store's version counter (its max
    # id moves on every write, which is what the cache staleness probe
    # watches). Never given an updated_at — rows are facts, not state.
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

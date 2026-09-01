# frozen_string_literal: true

# Stale-write protection moves from a whole-store version (serialized on the
# dial_locks anchor) to per-override optimistic locking: each dials row
# carries a version stamp and writes are guarded statements. The lock table
# goes away. Pre-release: the demo empties the overrides rather than
# backfilling stamps.
class PerOverrideVersions < ActiveRecord::Migration[8.1]
  def up
    drop_table :dial_locks
    execute "DELETE FROM dials"
    add_column :dials, :version, :bigint, null: false
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

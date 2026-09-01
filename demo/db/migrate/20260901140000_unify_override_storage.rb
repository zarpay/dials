# frozen_string_literal: true

# One table of overrides: the global is the override at the empty scope
# (canonical "{}"); a variation is the override at a non-empty scope. This
# replaces the dials + dial_variations pair — pre-release, so the demo just
# rebuilds the storage rather than migrating data. Mirrors the gem's install
# migration template.
class UnifyOverrideStorage < ActiveRecord::Migration[8.1]
  def up
    drop_table :dial_variations
    drop_table :dials

    create_table :dials do |t|
      t.string :key, null: false, limit: 100
      t.string :scope, null: false, limit: 255
      t.text :value, null: false
      t.timestamps
    end
    add_index :dials, [:key, :scope], unique: true
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

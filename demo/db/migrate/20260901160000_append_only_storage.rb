# frozen_string_literal: true

# The log becomes the state: one append-only dials table replaces the
# dials + dial_changes pair. Every write INSERTs a row; the newest row per
# (key, scope) stream is the current override; UNIQUE(key, scope, seq) makes
# writes atomic with no lock table. Adopted from PR #1's exploration, with
# the seq index closing its race. Pre-release: no data migration.
class AppendOnlyStorage < ActiveRecord::Migration[8.1]
  def up
    drop_table :dial_changes
    drop_table :dials

    create_table :dials do |t|
      t.string :key, null: false, limit: 100
      t.string :scope, null: false, limit: 255
      t.bigint :seq, null: false
      t.string :action, null: false
      t.text :value
      t.string :actor_type
      t.string :actor_id
      t.string :actor_label
      t.datetime :created_at, null: false
    end
    add_index :dials, [:key, :scope, :seq], unique: true
    add_index :dials, :key
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end

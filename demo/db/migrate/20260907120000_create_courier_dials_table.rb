# frozen_string_literal: true

# The Courier subsystem's own dials table. A namespace owns a table — same
# shape as the root's `dials`, different name — so the two subsystems' rows,
# history and stale-write sequences never mix.
class CreateCourierDialsTable < ActiveRecord::Migration[8.1]
  def change
    identity_collation = ("utf8mb4_bin" if connection.adapter_name.match?(/mysql/i))

    create_table :courier_dials do |t|
      t.string :key, null: false, limit: 100, collation: identity_collation
      t.string :scope, null: false, limit: 255, collation: identity_collation
      t.bigint :seq, null: false
      t.string :action, null: false
      t.text :value
      t.string :actor_type
      t.string :actor_id
      t.string :actor_label
      t.datetime :created_at, null: false
    end
    add_index :courier_dials, [:key, :scope, :seq], unique: true
    add_index :courier_dials, :key
  end
end

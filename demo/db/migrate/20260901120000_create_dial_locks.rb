# frozen_string_literal: true

# A single-row anchor for compare-and-swap dial writes (expected_version:):
# writers SELECT ... FOR UPDATE this row to serialize the version check with
# the change-log append. One row, no data. Mirrors the gem's install
# migration template.
class CreateDialLocks < ActiveRecord::Migration[8.1]
  def change
    create_table :dial_locks
    reversible do |dir|
      dir.up { execute "INSERT INTO dial_locks (id) VALUES (1)" }
    end
  end
end

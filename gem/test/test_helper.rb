# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "dials"
require "minitest/autorun"

module DialsTestSupport
  # Every test starts from a blank slate: no namespaces but the root, empty
  # registry, fresh in-memory store, no cache.
  def setup
    Dials.reset_namespaces!
    Dials.registry.reset!
    Dials.default.reset_config!
    Dials.reset_cache!
    Thread.current[Dials::TXN_WRITE_KEY] = nil
    super
  end

  ACTOR = "test-operator"

  # ONE sqlite connection for the whole suite — a second in-memory database
  # would silently drop the tables an earlier test file created. Each table
  # mirrors lib/generators/dials/install/templates/migration.rb.tt.
  def self.sqlite_schema!(*table_names)
    unless ActiveRecord::Base.connected?
      ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
      ActiveRecord::Schema.verbose = false
    end

    connection = ActiveRecord::Base.connection
    table_names.each do |name|
      next if connection.table_exists?(name)

      ActiveRecord::Schema.define do
        create_table name do |t|
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
        add_index name, %i[key scope seq], unique: true
        add_index name, :key
      end
    end
  end

  def define_standard_dials
    Dials.define do
      dial :merchant_fee_bps, default: 100, type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
           dimensions: { market: { enum: %w[KE NG BD] } }
      dial :signups_enabled, default: true, type: :boolean
      dial :free_delivery_threshold, default: 50, type: :integer, minimum: 0, maximum: 1_000_000,
           dimensions: { market: { enum: %w[KE NG BD] }, platform: { enum: %w[ios android web] } }
      dial :support_email, default: "support@example.com", type: :string
    end
  end
end

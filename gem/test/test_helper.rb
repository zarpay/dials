# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "dials"

# The gem tests run against a real database, because a fake one would not
# exercise the thing most worth exercising: the single append-only table.
ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table :dials, force: true do |t|
    t.string   :key,   null: false
    t.string   :scope, null: false, default: "{}"
    t.text     :value
    t.string   :actor_type
    t.string   :actor_id
    t.string   :actor_label
    t.datetime :created_at, null: false
  end
  add_index :dials, %i[key scope id]
end

Operator = Struct.new(:id, :email)

class DialsTest < Minitest::Test
  OPS = Operator.new(7, "ops@example.com")

  def setup
    Dials.undefine_all!
    Dials::Record.delete_all
    Dials.actor_label = nil
    # Tests want every write visible at once, with no waiting on a probe.
    Dials.cache_ttl = 0
  end

  # The two dials most tests need: one plain, one varied.
  def declare_fee_and_switch
    Dials.define do
      dial :checkout_fee_bps, default: 250, type: _Integer(1..10_000),
           unit: "bps", description: "Fee charged at checkout.",
           variants: { market: %w[KE NG BD] }

      dial :signups_enabled, default: true, type: _Boolean
    end
  end

  def count_queries
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_, _, _, _, payload|
      queries << payload[:sql] unless payload[:name] == "SCHEMA"
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end
end

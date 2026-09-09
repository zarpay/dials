# frozen_string_literal: true

require "test_helper"
require "dials/active_record"

# Two namespaces, two tables, one database.
class NamespaceActiveRecordTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    DialsTestSupport.sqlite_schema!(:shipping_dials, :payouts_dials)

    @shipping = Dials.namespace(:shipping) { |c| c.store = :active_record }
    @payouts = Dials.namespace(:payouts) { |c| c.store = :active_record }
    [@shipping, @payouts].each { |ns| ns.store.model.delete_all }

    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }
  end

  def test_each_namespace_writes_to_its_own_table
    assert_equal "shipping_dials", @shipping.store.model.table_name
    assert_equal "payouts_dials", @payouts.store.model.table_name

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal 60, @shipping.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds
    assert_equal 1, @shipping.store.model.count
    assert_equal 0, @payouts.store.model.count
  end

  def test_config_table_name_overrides_the_derived_name
    DialsTestSupport.sqlite_schema!(:engine_settings)
    @shipping.configure { |c| c.table_name = "engine_settings" }

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal "engine_settings", @shipping.store.model.table_name
    assert_equal 60, @shipping.timeout_seconds
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM shipping_dials").to_i
  end

  def test_a_table_named_for_a_reserved_word_still_loads_state
    # The store writes one query by hand; an unquoted "order" would be a
    # syntax error the first time the namespace read anything.
    DialsTestSupport.sqlite_schema!(:order)
    @shipping.configure { |c| c.table_name = "order" }

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal 60, @shipping.timeout_seconds
  end

  def test_history_is_per_namespace
    @shipping.adjust_timeout_seconds(60, actor: ACTOR)
    @payouts.adjust_timeout_seconds(6, actor: ACTOR)

    assert_equal [60], @shipping.changes.map(&:new_value)
    assert_equal [6], @payouts.changes.map(&:new_value)
  end

  def test_an_in_transaction_write_leaves_another_namespace_on_the_shared_cache
    Dials.configure { |c| c.cache_ttl = nil } # only busts converge

    payouts_snapshot = @payouts.cache.snapshot

    @shipping.store.model.transaction do
      @shipping.adjust_timeout_seconds(60, actor: ACTOR)

      assert_equal 60, @shipping.timeout_seconds, "the writer sees its own uncommitted write"
      assert_nil @shipping.cache.instance_variable_get(:@snapshot),
                 "the uncommitted write never lands in the shared cache"
      assert_same payouts_snapshot, @payouts.cache.snapshot,
                  "the other namespace keeps reading its published snapshot"
      assert_nil Thread.current[Dials::TXN_WRITE_KEY],
                 "the root namespace's marker is untouched"
    end

    assert_equal 60, @shipping.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds
  end
end

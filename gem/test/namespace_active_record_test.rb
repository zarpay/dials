# frozen_string_literal: true

require "test_helper"
require "dials/active_record"

# Two namespaces, two tables, one database.
class NamespaceActiveRecordTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    DialsTestSupport.sqlite_schema!(:transfers_dials, :payouts_dials)

    @transfers = Dials.namespace(:transfers) { |c| c.store = :active_record }
    @payouts = Dials.namespace(:payouts) { |c| c.store = :active_record }
    [@transfers, @payouts].each { |ns| ns.store.model.delete_all }

    @transfers.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }
  end

  def test_each_namespace_writes_to_its_own_table
    assert_equal "transfers_dials", @transfers.store.model.table_name
    assert_equal "payouts_dials", @payouts.store.model.table_name

    @transfers.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal 60, @transfers.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds
    assert_equal 1, @transfers.store.model.count
    assert_equal 0, @payouts.store.model.count
  end

  def test_config_table_name_overrides_the_derived_name
    DialsTestSupport.sqlite_schema!(:engine_settings)
    @transfers.configure { |c| c.table_name = "engine_settings" }

    @transfers.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal "engine_settings", @transfers.store.model.table_name
    assert_equal 60, @transfers.timeout_seconds
    assert_equal 0, ActiveRecord::Base.connection.select_value("SELECT COUNT(*) FROM transfers_dials").to_i
  end

  def test_history_is_per_namespace
    @transfers.adjust_timeout_seconds(60, actor: ACTOR)
    @payouts.adjust_timeout_seconds(6, actor: ACTOR)

    assert_equal [60], @transfers.changes.map(&:new_value)
    assert_equal [6], @payouts.changes.map(&:new_value)
  end

  def test_an_in_transaction_write_leaves_another_namespace_on_the_shared_cache
    Dials.configure { |c| c.cache_ttl = nil } # only busts converge

    payouts_snapshot = @payouts.cache.snapshot

    @transfers.store.model.transaction do
      @transfers.adjust_timeout_seconds(60, actor: ACTOR)

      assert_equal 60, @transfers.timeout_seconds, "the writer sees its own uncommitted write"
      assert_nil @transfers.cache.instance_variable_get(:@snapshot),
                 "the uncommitted write never lands in the shared cache"
      assert_same payouts_snapshot, @payouts.cache.snapshot,
                  "the other namespace keeps reading its published snapshot"
      assert_nil Thread.current[Dials::TXN_WRITE_KEY],
                 "the root namespace's marker is untouched"
    end

    assert_equal 60, @transfers.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds
  end
end

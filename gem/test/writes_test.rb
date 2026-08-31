# frozen_string_literal: true

require "test_helper"

class WritesTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def test_actor_is_required
    assert_raises(Dials::MissingActor) { Dials.set(:merchant_fee_bps, 150, actor: nil) }
    assert_raises(Dials::MissingActor) { Dials.clear(:merchant_fee_bps, actor: nil) }
  end

  def test_set_validates_type_and_bounds
    assert_raises(Dials::InvalidValue) { Dials.set(:merchant_fee_bps, "150", actor: ACTOR) }
    assert_raises(Dials::InvalidValue) { Dials.set(:merchant_fee_bps, 0, actor: ACTOR) }
    assert_raises(Dials::InvalidValue) { Dials.set(:merchant_fee_bps, nil, actor: ACTOR) }
  end

  def test_variation_bounds_apply_same_as_global
    assert_raises(Dials::InvalidValue) do
      Dials.set(:merchant_fee_bps, 10_001, scope: { market: "KE" }, actor: ACTOR)
    end
  end

  def test_set_with_scope_on_variantless_dial_rejected
    assert_raises(Dials::InvalidScope) do
      Dials.set(:signups_enabled, false, scope: { market: "KE" }, actor: ACTOR)
    end
  end

  def test_set_with_partial_scope_rejected_in_v1
    assert_raises(Dials::InvalidScope) do
      Dials.set(:free_delivery_threshold, 10, scope: { market: "KE" }, actor: ACTOR)
    end
  end

  def test_changes_are_logged_newest_first_with_attribution
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: ACTOR)

    changes = Dials.changes(key: :merchant_fee_bps)
    assert_equal 3, changes.length

    clear_change, variation_change, global_change = changes

    assert_equal "clear", clear_change.action
    assert_equal({ market: "KE" }, clear_change.scope)
    assert_equal 90, clear_change.old_value
    assert_nil clear_change.new_value

    assert_equal "set", variation_change.action
    assert_nil variation_change.old_value
    assert_equal 90, variation_change.new_value

    assert_equal "set", global_change.action
    assert global_change.global?
    assert_nil global_change.old_value
    assert_equal 150, global_change.new_value
    assert_equal ACTOR, global_change.actor_label
  end

  def test_second_set_records_old_value
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 200, actor: ACTOR)
    assert_equal 150, Dials.changes(key: :merchant_fee_bps).first.old_value
  end

  def test_clearing_nothing_is_a_silent_noop
    refute Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_empty Dials.changes(key: :merchant_fee_bps)
  end

  def test_changes_filter_and_limit
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:support_email, "help@example.com", actor: ACTOR)
    assert_equal 2, Dials.changes.length
    assert_equal [:support_email], Dials.changes(key: :support_email).map(&:key)
    assert_equal 1, Dials.changes(limit: 1).length
  end

  AdminUser = Struct.new(:id, :email)

  def test_actor_object_contributes_type_id_and_label
    admin = AdminUser.new(42, "keith@example.com")
    Dials.set(:merchant_fee_bps, 150, actor: admin)

    change = Dials.changes.first
    assert_equal "WritesTest::AdminUser", change.actor_type
    assert_equal "42", change.actor_id
    assert_equal "keith@example.com", change.actor_label
  end

  def test_actor_label_is_configurable
    Dials.configure { |c| c.actor_label = ->(actor) { "custom:#{actor}" } }
    Dials.set(:merchant_fee_bps, 150, actor: "ops")
    assert_equal "custom:ops", Dials.changes.first.actor_label
  end

  def test_write_is_read_back_immediately_in_same_process
    Dials.configure { |c| c.cache_ttl = 3600 } # probe would never fire
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE")
  end
end

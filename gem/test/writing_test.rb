# frozen_string_literal: true

require "test_helper"

class WritingTest < DialsTest
  def test_set_returns_the_stored_value_and_the_next_read_agrees
    declare_fee_and_switch

    assert_equal 120, Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)
    assert_equal 120, Dials.checkout_fee_bps.for(market: "BD")
  end

  def test_a_value_that_fails_the_type_is_refused_and_nothing_is_written
    declare_fee_and_switch

    assert_raises(Dials::InvalidValue) { Dials.checkout_fee_bps.set(0, actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.checkout_fee_bps.set("120", actor: OPS) }
    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
    assert_equal 0, Dials::Record.count
  end

  def test_nil_is_never_a_value
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidValue) { Dials.signups_enabled.set(nil, actor: OPS) }
    assert_match(/clear the dial instead/, error.message)
  end

  def test_false_is_a_real_value_so_a_kill_switch_can_be_turned_off
    declare_fee_and_switch
    Dials.signups_enabled.set(false, actor: OPS)

    assert_equal false, Dials.signups_enabled.value
    assert Dials.signups_enabled.clear(actor: OPS)
    assert_equal true, Dials.signups_enabled.value
  end

  def test_every_write_needs_an_actor
    declare_fee_and_switch

    assert_raises(ArgumentError) { Dials.signups_enabled.set(false) }
    error = assert_raises(Dials::Error) { Dials.signups_enabled.set(false, actor: nil) }
    assert_match(/needs an actor/, error.message)
  end

  def test_clearing_a_variant_falls_back_to_the_global
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(300, actor: OPS)
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)

    assert Dials.checkout_fee_bps.clear(market: "BD", actor: OPS)
    assert_equal 300, Dials.checkout_fee_bps.for(market: "BD")
  end

  def test_clearing_the_global_falls_back_to_the_code_default_and_leaves_variants_alone
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(300, actor: OPS)
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)

    assert Dials.checkout_fee_bps.clear(actor: OPS)
    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
    assert_equal 120, Dials.checkout_fee_bps.for(market: "BD")
  end

  def test_clearing_nothing_is_a_no_op_that_writes_no_history
    declare_fee_and_switch

    refute Dials.checkout_fee_bps.clear(market: "BD", actor: OPS)
    assert_equal 0, Dials::Record.count
  end

  def test_the_history_records_every_turn_with_who_turned_it
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)
    Dials.checkout_fee_bps.clear(market: "BD", actor: "rake task")

    history = Dials.checkout_fee_bps.history.to_a
    assert_equal 2, history.size

    cleared, set = history
    assert_predicate cleared, :cleared?
    assert_nil cleared.actor_type
    assert_equal "rake task", cleared.actor_label

    refute_predicate set, :cleared?
    assert_equal 120, set.value
    assert_equal({ market: "BD" }, set.scope_hash)
    assert_equal "Operator", set.actor_type
    assert_equal "7", set.actor_id
    assert_equal "ops@example.com", set.actor_label
  end

  def test_the_actor_label_is_configurable
    declare_fee_and_switch
    Dials.actor_label = ->(actor) { "operator #{actor.id}" }
    Dials.signups_enabled.set(false, actor: OPS)

    assert_equal "operator 7", Dials.signups_enabled.history.first.actor_label
  end

  def test_history_rows_are_facts_and_refuse_to_be_rewritten
    declare_fee_and_switch
    Dials.signups_enabled.set(false, actor: OPS)

    assert_raises(ActiveRecord::ReadOnlyRecord) { Dials.signups_enabled.history.first.update!(value: "true") }
  end

  def test_a_value_that_would_not_survive_the_database_is_refused
    Dials.define { dial :blob, default: { "a" => 1 }, type: Hash }

    error = assert_raises(Dials::InvalidValue) { Dials.blob.set({ a: 1 }, actor: OPS) }
    assert_match(/does not survive a JSON round trip/, error.message)
  end

  def test_json_values_round_trip
    Dials.define { dial :blob, default: {}, type: _JSONData }
    Dials.blob.set({ "limits" => { "daily" => 100 }, "tags" => %w[a b] }, actor: OPS)

    assert_equal({ "limits" => { "daily" => 100 }, "tags" => %w[a b] }, Dials.blob.value)
  end

  def test_nothing_is_ever_updated_or_deleted
    declare_fee_and_switch
    3.times { |i| Dials.checkout_fee_bps.set(100 + i, actor: OPS) }
    Dials.checkout_fee_bps.clear(actor: OPS)

    assert_equal 4, Dials::Record.count
    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
  end

  def test_cast_lets_a_write_surface_validate_before_it_writes
    declare_fee_and_switch

    assert_equal 120, Dials.checkout_fee_bps.cast(120)
    assert_raises(Dials::InvalidValue) { Dials.checkout_fee_bps.cast(0) }
    assert_equal 0, Dials::Record.count
  end
end

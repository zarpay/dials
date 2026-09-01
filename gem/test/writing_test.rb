# frozen_string_literal: true

require "test_helper"

class WritingTest < DialsTest
  def test_adjust_returns_the_stored_value_and_the_next_read_agrees
    declare_fee_and_switch

    assert_equal 120, Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)
    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_a_value_that_fails_the_type_is_refused_and_nothing_is_written
    declare_fee_and_switch

    assert_raises(Dials::InvalidValue) { Dials.adjust(:checkout_fee_bps, 0, actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.adjust(:checkout_fee_bps, "120", actor: OPS) }
    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
    assert_equal 0, Dials::Record.count
  end

  def test_nil_is_never_a_value
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidValue) { Dials.adjust(:signups_enabled, nil, actor: OPS) }
    assert_match(/reset the dial instead/, error.message)
  end

  def test_false_is_a_real_value_so_a_kill_switch_can_be_turned_off
    declare_fee_and_switch
    Dials.adjust(:signups_enabled, false, actor: OPS)

    assert_equal false, Dials.signups_enabled
    assert Dials.reset(:signups_enabled, actor: OPS)
    assert_equal true, Dials.signups_enabled
  end

  def test_every_write_needs_an_actor_unless_a_default_is_declared
    declare_fee_and_switch

    error = assert_raises(Dials::Error) { Dials.adjust(:signups_enabled, false) }
    assert_match(/needs an actor/, error.message)
    assert_equal 0, Dials::Record.count
  end

  def test_a_default_actor_covers_writes_that_name_none
    declare_fee_and_switch
    Dials.default_actor = "rake task"
    Dials.adjust(:signups_enabled, false)

    assert_equal "rake task", Dials[:signups_enabled].history.first.actor_label
  end

  def test_a_default_actor_can_be_a_callable_evaluated_per_write
    declare_fee_and_switch
    who = "first"
    Dials.default_actor = -> { who }

    Dials.adjust(:signups_enabled, false)
    who = "second"
    Dials.adjust(:signups_enabled, true)

    assert_equal %w[second first], Dials[:signups_enabled].history.map(&:actor_label)
  end

  def test_an_explicit_actor_beats_the_default
    declare_fee_and_switch
    Dials.default_actor = "rake task"
    Dials.adjust(:signups_enabled, false, actor: OPS)

    assert_equal "ops@example.com", Dials[:signups_enabled].history.first.actor_label
  end

  def test_resetting_a_scoped_override_falls_back_to_the_global
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

    assert Dials.reset(:checkout_fee_bps, market: "BD", actor: OPS)
    assert_equal 300, Dials.checkout_fee_bps(market: "BD")
  end

  def test_resetting_the_global_falls_back_to_the_code_default_and_leaves_scoped_overrides_alone
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

    assert Dials.reset(:checkout_fee_bps, actor: OPS)
    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_resetting_nothing_is_a_no_op_that_writes_no_history
    declare_fee_and_switch

    refute Dials.reset(:checkout_fee_bps, market: "BD", actor: OPS)
    assert_equal 0, Dials::Record.count
  end

  def test_the_history_records_every_turn_with_who_turned_it
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)
    Dials.reset(:checkout_fee_bps, market: "BD", actor: "rake task")

    history = Dials[:checkout_fee_bps].history.to_a
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
    Dials.adjust(:signups_enabled, false, actor: OPS)

    assert_equal "operator 7", Dials[:signups_enabled].history.first.actor_label
  end

  def test_history_rows_are_facts_and_refuse_to_be_rewritten
    declare_fee_and_switch
    Dials.adjust(:signups_enabled, false, actor: OPS)

    assert_raises(ActiveRecord::ReadOnlyRecord) { Dials[:signups_enabled].history.first.update!(value: "true") }
  end

  def test_a_value_that_would_not_survive_the_database_is_refused
    Dials.define { dial :blob, default: { "a" => 1 }, type: Hash }

    error = assert_raises(Dials::InvalidValue) { Dials.adjust(:blob, { a: 1 }, actor: OPS) }
    assert_match(/does not survive a JSON round trip/, error.message)
  end

  def test_json_values_round_trip
    Dials.define { dial :blob, default: {}, type: _JSONData }
    Dials.adjust(:blob, { "limits" => { "daily" => 100 }, "tags" => %w[a b] }, actor: OPS)

    assert_equal({ "limits" => { "daily" => 100 }, "tags" => %w[a b] }, Dials.blob)
  end

  def test_nothing_is_ever_updated_or_deleted
    declare_fee_and_switch
    3.times { |i| Dials.adjust(:checkout_fee_bps, 100 + i, actor: OPS) }
    Dials.reset(:checkout_fee_bps, actor: OPS)

    assert_equal 4, Dials::Record.count
    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
  end

  def test_a_stale_write_is_refused_when_the_override_moved
    declare_fee_and_switch
    token = Dials[:checkout_fee_bps].version(market: "BD")
    assert_equal 0, token # nothing stored yet

    # Someone else edits between this operator loading the form and saving it.
    Dials.adjust(:checkout_fee_bps, 300, market: "BD", actor: "another admin")

    error = assert_raises(Dials::StaleWrite) do
      Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS, if_unchanged_since: token)
    end
    assert_match(/changed since you read it/, error.message)

    assert_equal 300, Dials.checkout_fee_bps(market: "BD")
    assert_equal 1, Dials::Record.count
  end

  def test_a_write_carrying_a_current_token_goes_through
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, market: "BD", actor: OPS)
    token = Dials[:checkout_fee_bps].version(market: "BD")

    assert_equal 120, Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS, if_unchanged_since: token)
    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_the_token_is_per_override_so_unrelated_dials_never_false_conflict
    declare_fee_and_switch
    token = Dials[:checkout_fee_bps].version(market: "BD")

    Dials.adjust(:signups_enabled, false, actor: OPS) # a different dial
    Dials.adjust(:checkout_fee_bps, 900, market: "KE", actor: OPS) # a different scope

    assert_equal 120, Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS, if_unchanged_since: token)
  end

  def test_a_reset_can_carry_a_token_too
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, market: "BD", actor: OPS)
    stale = Dials[:checkout_fee_bps].version(market: "BD")
    Dials.adjust(:checkout_fee_bps, 400, market: "BD", actor: "another admin")

    assert_raises(Dials::StaleWrite) do
      Dials.reset(:checkout_fee_bps, market: "BD", actor: OPS, if_unchanged_since: stale)
    end
    assert_equal 400, Dials.checkout_fee_bps(market: "BD")
  end

  def test_a_token_survives_a_clear_and_reset_without_repeating_itself
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, market: "BD", actor: OPS)
    first = Dials[:checkout_fee_bps].version(market: "BD")
    Dials.reset(:checkout_fee_bps, market: "BD", actor: OPS)
    Dials.adjust(:checkout_fee_bps, 300, market: "BD", actor: OPS)

    # Same value, same scope, but ids only grow — so the old token cannot be
    # mistaken for the current one.
    refute_equal first, Dials[:checkout_fee_bps].version(market: "BD")
  end

  def test_cast_lets_a_write_surface_validate_before_it_writes
    declare_fee_and_switch

    assert_equal 120, Dials[:checkout_fee_bps].cast(120)
    assert_raises(Dials::InvalidValue) { Dials[:checkout_fee_bps].cast(0) }
    assert_equal 0, Dials::Record.count
  end
end

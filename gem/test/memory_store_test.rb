# frozen_string_literal: true

require "test_helper"

# The memory store must behave byte-for-byte like the ActiveRecord store, so
# a client test suite running on :memory proves what production will do.
class MemoryStoreTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    Dials.define { dial :fee_table, { "base" => 1 }, type: :json }
  end

  def test_stored_values_are_detached_from_caller_objects
    value = { "base" => 2, "tiers" => [1, 2] }
    Dials.set(:fee_table, value, actor: ACTOR)

    value["base"] = 999
    value["tiers"] << 999

    assert_equal({ "base" => 2, "tiers" => [1, 2] }, Dials.get(:fee_table),
                 "mutating the caller's object after set must not change the stored override")
  end

  def test_change_log_values_are_detached_and_frozen
    Dials.set(:fee_table, { "base" => 2 }, actor: ACTOR)
    logged = Dials.changes.first.new_value

    assert_equal({ "base" => 2 }, logged)
    assert logged.frozen?, "history is immutable — a caller cannot rewrite the retained audit log"
    assert_raises(FrozenError) { logged["base"] = 999 }
    Dials.reload!
    assert_equal({ "base" => 2 }, Dials.get(:fee_table))
  end

  def test_json_round_trip_matches_active_record_semantics
    # Symbol keys are rejected at validation (round-trip fidelity), exactly
    # like the ActiveRecord store — no store-dependent behavior difference.
    assert_raises(Dials::InvalidValue) { Dials.set(:fee_table, { base: 2 }, actor: ACTOR) }
  end

  def test_false_round_trips_through_the_memory_store
    Dials.define { dial :flag, true, type: :boolean }
    Dials.set(:flag, false, actor: ACTOR)
    Dials.reload!
    assert_equal false, Dials.get(:flag)
  end
end

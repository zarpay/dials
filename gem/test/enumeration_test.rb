# frozen_string_literal: true

require "test_helper"

class EnumerationTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  # -- Dials.scoped_overrides -------------------------------------------------------

  def test_scoped_overrides_returns_parsed_scopes_never_canonical_strings
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")
    Dials.adjust_merchant_fee_bps(150, actor: ACTOR, market: "NG")

    assert_equal({ { market: "BD" } => 120, { market: "NG" } => 150 }, Dials.scoped_overrides(:merchant_fee_bps))
  end

  def test_scoped_overrides_is_empty_when_nothing_scoped_is_stored
    assert_equal({}, Dials.scoped_overrides(:merchant_fee_bps))
    assert_equal({}, Dials.scoped_overrides(:signups_enabled))
  end

  def test_scoped_overrides_raises_for_unknown_keys
    assert_raises(Dials::UnknownDial) { Dials.scoped_overrides(:no_such_dial) }
  end

  def test_scoped_overrides_result_is_deep_frozen
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")
    result = Dials.scoped_overrides(:merchant_fee_bps)

    assert result.frozen?
    assert result.keys.first.frozen?
    assert_raises(FrozenError) { result[{ market: "KE" }] = 1 }
  end

  # -- Dials.overview ---------------------------------------------------------

  def test_overview_covers_every_registered_dial_in_order
    overview = Dials.overview
    assert_equal Dials.registry.keys, overview.dials.map(&:key)
  end

  def test_overview_distinguishes_global_override_absent_from_present
    overview = Dials.overview
    state = overview.dials.find { |d| d.key == :signups_enabled }
    refute state.global_override?
    assert_nil state.global_value

    # The distinction that matters: an override to false is PRESENT.
    Dials.adjust_signups_enabled(false, actor: ACTOR)
    state = Dials.overview.dials.find { |d| d.key == :signups_enabled }
    assert state.global_override?
    assert_equal false, state.global_value
  end

  def test_overview_carries_scoped_overrides_and_json_schema
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")

    state = Dials.overview.dials.find { |d| d.key == :merchant_fee_bps }
    assert_equal({ { market: "BD" } => 120 }, state.scoped_overrides)
    assert_equal "integer", state.json_schema["type"]
    assert_equal 1, state.json_schema["minimum"]
    assert_equal state.definition, Dials.registry.fetch(:merchant_fee_bps)
  end

  def test_overview_version_is_an_opaque_token_that_moves_on_every_write
    before = Dials.overview.version
    assert_kind_of String, before
    assert before.frozen?

    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    after = Dials.overview.version
    refute_equal before, after
  end

  def test_overview_carries_per_override_versions
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")

    state = Dials.overview.dials.find { |d| d.key == :merchant_fee_bps }
    assert_kind_of String, state.global_version
    refute_equal Dials::ABSENT_VERSION, state.global_version
    assert_equal [{ market: "BD" }], state.scoped_override_versions.keys
    refute_equal state.global_version, state.scoped_override_versions[{ market: "BD" }]

    untouched = Dials.overview.dials.find { |d| d.key == :signups_enabled }
    assert_equal Dials::ABSENT_VERSION, untouched.global_version
    assert_empty untouched.scoped_override_versions
  end

  def test_overview_is_one_coherent_snapshot
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")
    overview = Dials.overview

    # A write AFTER the overview was taken is not in it, and its version
    # token still names the state it rendered.
    Dials.adjust_merchant_fee_bps(999, actor: ACTOR, market: "BD")
    state = overview.dials.find { |d| d.key == :merchant_fee_bps }
    assert_equal 120, state.scoped_overrides[{ market: "BD" }]
    refute_equal Dials.overview.version, overview.version
  end

  def test_overview_structures_are_frozen
    overview = Dials.overview
    assert overview.frozen?
    assert overview.dials.frozen?
    assert(overview.dials.all?(&:frozen?))
  end
end

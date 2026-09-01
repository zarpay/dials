# frozen_string_literal: true

require "test_helper"

class ResolutionTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def test_code_default_when_nothing_stored
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal true, Dials.get(:signups_enabled)
  end

  def test_global_override_beats_default
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "NG")
  end

  def test_scoped_override_beats_global_override
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "NG")
  end

  def test_clearing_a_scoped_override_falls_back_to_global
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    assert Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_clearing_the_global_falls_back_to_code_default
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    assert Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_scoped_override_survives_a_cleared_global
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "NG")
  end

  def test_false_override_resolves_as_false
    Dials.set(:signups_enabled, false, actor: ACTOR)
    assert_equal false, Dials.get(:signups_enabled)
  end

  def test_multi_dimension_exact_scope
    Dials.set(:free_delivery_threshold, 25, scope: { market: "KE", platform: "ios" }, actor: ACTOR)
    assert_equal 25, Dials.get(:free_delivery_threshold, market: "KE", platform: "ios")
    assert_equal 50, Dials.get(:free_delivery_threshold, market: "KE", platform: "web")
  end

  def test_read_scope_must_be_exact
    assert_raises(Dials::InvalidScope) { Dials.get(:merchant_fee_bps) }
    assert_raises(Dials::InvalidScope) { Dials.get(:free_delivery_threshold, market: "KE") }
    assert_raises(Dials::InvalidScope) { Dials.get(:signups_enabled, market: "KE") }
    assert_raises(Dials::InvalidScope) { Dials.get(:merchant_fee_bps, market: "US") }
  end

  def test_unknown_dial_raises
    assert_raises(Dials::UnknownDial) { Dials.get(:merchant_fee) }
  end

  def test_scope_spelling_never_matters
    Dials.set(:merchant_fee_bps, 90, scope: { "market" => :KE }, actor: ACTOR)
    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_json_values_are_deep_frozen_on_read
    Dials.define { dial :fee_table, default: { "base" => 1 }, type: :json }
    Dials.set(:fee_table, { "base" => 2, "tiers" => [1, 2] }, actor: ACTOR)
    value = Dials.get(:fee_table)
    assert value.frozen?
    assert_raises(FrozenError) { value["base"] = 99 }
  end

  # The resolver is intentionally more general than the v1 write rule: stored
  # partial scopes (subset of declared dimensions) already resolve with
  # most-specific-wins, ties broken by declared dimension order. Exercised
  # directly against a hand-built snapshot because the write path does not
  # allow partials yet.
  def test_future_partial_scopes_most_specific_wins
    definition = Dials.registry.fetch(:free_delivery_threshold)
    snapshot = Dials::Snapshot.new(
      globals: { free_delivery_threshold: 60 },
      scoped_overrides: {
        free_delivery_threshold: {
          Dials::Scope.canonical({ market: "KE" }) => 40,
          Dials::Scope.canonical({ platform: "ios" }) => 30,
          Dials::Scope.canonical({ market: "KE", platform: "ios" }) => 20
        }
      },
      version: 1
    )

    resolve = ->(scope) { Dials::Resolver.resolve(definition, Dials::Scope.normalize(scope), snapshot) }

    # Full match beats both partials.
    assert_equal 20, resolve.call({ market: "KE", platform: "ios" })
    # Only the market partial matches.
    assert_equal 40, resolve.call({ market: "KE", platform: "web" })
    # Only the platform partial matches.
    assert_equal 30, resolve.call({ market: "NG", platform: "ios" })
    # Nothing matches: global override.
    assert_equal 60, resolve.call({ market: "NG", platform: "web" })
  end

  def test_future_partial_tie_breaks_by_declared_dimension_order
    definition = Dials.registry.fetch(:free_delivery_threshold) # declares market, then platform
    snapshot = Dials::Snapshot.new(
      globals: {},
      scoped_overrides: {
        free_delivery_threshold: {
          Dials::Scope.canonical({ market: "KE" }) => 40,
          Dials::Scope.canonical({ platform: "ios" }) => 30
        }
      },
      version: 1
    )

    value = Dials::Resolver.resolve(definition, Dials::Scope.normalize({ market: "KE", platform: "ios" }), snapshot)
    assert_equal 40, value, "market is declared before platform, so the market partial outranks the platform partial"
  end
end

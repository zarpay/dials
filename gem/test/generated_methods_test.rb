# frozen_string_literal: true

require "test_helper"

class GeneratedMethodsTest < Minitest::Test
  include DialsTestSupport

  def test_declaring_a_dial_generates_its_three_methods
    define_standard_dials
    %i[use_merchant_fee_bps adjust_merchant_fee_bps clear_merchant_fee_bps].each do |name|
      assert_respond_to Dials, name
    end
  end

  def test_use_resolves_through_the_same_layers_as_get
    define_standard_dials
    assert_equal 100, Dials.use_merchant_fee_bps(market: "KE")

    Dials.adjust_merchant_fee_bps(250, actor: ACTOR)
    assert_equal 250, Dials.use_merchant_fee_bps(market: "KE")

    Dials.adjust_merchant_fee_bps(300, actor: ACTOR, market: "KE")
    assert_equal 300, Dials.use_merchant_fee_bps(market: "KE")
    assert_equal 250, Dials.use_merchant_fee_bps(market: "NG")
  end

  def test_use_enforces_exact_scope
    define_standard_dials
    assert_raises(Dials::InvalidScope) { Dials.use_merchant_fee_bps }
    assert_raises(Dials::InvalidScope) { Dials.use_signups_enabled(market: "KE") }
  end

  def test_adjust_validates_value_like_set
    define_standard_dials
    assert_raises(Dials::InvalidValue) { Dials.adjust_merchant_fee_bps(0, actor: ACTOR) }
    assert_raises(Dials::InvalidScope) { Dials.adjust_support_email("x@example.com", actor: ACTOR, market: "KE") }
  end

  def test_adjust_without_actor_raises_unless_a_default_actor_is_configured
    define_standard_dials
    assert_raises(Dials::MissingActor) { Dials.adjust_signups_enabled(false) }
  end

  def test_false_is_storable_through_adjust
    define_standard_dials
    Dials.adjust_signups_enabled(false, actor: ACTOR)
    assert_equal false, Dials.use_signups_enabled
  end

  def test_clear_returns_resolution_to_the_layer_below
    define_standard_dials
    Dials.adjust_merchant_fee_bps(250, actor: ACTOR)
    Dials.adjust_merchant_fee_bps(300, actor: ACTOR, market: "KE")

    assert_equal true, Dials.clear_merchant_fee_bps(actor: ACTOR, market: "KE")
    assert_equal 250, Dials.use_merchant_fee_bps(market: "KE")

    assert_equal true, Dials.clear_merchant_fee_bps(actor: ACTOR)
    assert_equal 100, Dials.use_merchant_fee_bps(market: "KE")

    assert_equal false, Dials.clear_merchant_fee_bps(actor: ACTOR)
  end

  def test_testing_overrides_are_visible_through_use
    define_standard_dials
    Dials::Testing.with_overrides(merchant_fee_bps: 999) do
      assert_equal 999, Dials.use_merchant_fee_bps(market: "KE")
    end
    assert_equal 100, Dials.use_merchant_fee_bps(market: "KE")
  end

  def test_registry_reset_removes_generated_methods
    define_standard_dials
    Dials.registry.reset!

    refute_respond_to Dials, :use_merchant_fee_bps
    assert_raises(NoMethodError) { Dials.use_merchant_fee_bps(market: "KE") }
  end

  def test_redeclaring_after_reset_regenerates_cleanly
    define_standard_dials
    Dials.registry.reset!
    define_standard_dials

    assert_equal 100, Dials.use_merchant_fee_bps(market: "KE")
  end

  def test_name_collision_with_an_existing_method_raises_and_registers_nothing
    Dials.define_singleton_method(:use_taken) { :occupied }

    error = assert_raises(Dials::InvalidDefinition) do
      Dials.define { dial :taken, default: 1, type: :integer }
    end
    assert_match(/use_taken/, error.message)
    refute Dials.registry.defined?(:taken)
    refute_respond_to Dials, :adjust_taken
  ensure
    Dials.singleton_class.remove_method(:use_taken)
  end

  def test_actor_is_a_reserved_dimension_name
    error = assert_raises(Dials::InvalidDefinition) do
      Dials.define { dial :fee, default: 1, type: :integer, dimensions: { actor: %w[a b] } }
    end
    assert_match(/actor is a reserved dimension name/, error.message)
  end
end

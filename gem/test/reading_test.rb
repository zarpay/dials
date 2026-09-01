# frozen_string_literal: true

require "test_helper"

class ReadingTest < DialsTest
  def test_an_unset_dial_reads_its_code_default
    declare_fee_and_switch

    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
    assert_equal 250, Dials.checkout_fee_bps.for
    assert_equal true, Dials.signups_enabled.value
  end

  def test_a_global_override_beats_the_default_everywhere
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(300, actor: OPS)

    assert_equal 300, Dials.checkout_fee_bps.for(market: "KE")
    assert_equal 300, Dials.checkout_fee_bps.for(market: "BD")
    assert_equal 300, Dials.checkout_fee_bps.for
  end

  def test_a_variant_beats_the_global_only_in_its_own_scope
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(300, actor: OPS)
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)

    assert_equal 120, Dials.checkout_fee_bps.for(market: "BD")
    assert_equal 300, Dials.checkout_fee_bps.for(market: "KE")
    assert_equal 300, Dials.checkout_fee_bps.for
  end

  def test_the_example_from_the_readme
    declare_fee_and_switch

    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)
    assert_equal 120, Dials.checkout_fee_bps.for(market: "BD")
    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
  end

  def test_the_most_specific_stored_scope_wins
    Dials.define do
      dial :fee, default: 250, type: Integer,
           variants: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.fee.set(300, actor: OPS)
    Dials.fee.set(200, market: "BD", actor: OPS)
    Dials.fee.set(100, market: "BD", platform: "ios", actor: OPS)

    assert_equal 100, Dials.fee.for(market: "BD", platform: "ios")
    assert_equal 200, Dials.fee.for(market: "BD", platform: "android")
    assert_equal 300, Dials.fee.for(market: "KE", platform: "ios")
  end

  def test_a_partial_scope_covers_every_dimension_it_does_not_name
    Dials.define do
      dial :fee, default: 250, type: Integer,
           variants: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.fee.set(150, platform: "ios", actor: OPS)

    assert_equal 150, Dials.fee.for(market: "KE", platform: "ios")
    assert_equal 150, Dials.fee.for(market: "BD", platform: "ios")
    assert_equal 250, Dials.fee.for(market: "BD", platform: "android")
  end

  def test_equally_specific_scopes_are_broken_by_declaration_order
    Dials.define do
      dial :fee, default: 250, type: Integer,
           variants: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.fee.set(111, market: "BD", actor: OPS)
    Dials.fee.set(222, platform: "ios", actor: OPS)

    # Both match; market is declared first, so market wins.
    assert_equal 111, Dials.fee.for(market: "BD", platform: "ios")
  end

  def test_a_scope_naming_a_dimension_the_dial_does_not_have_raises
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps.for(platform: "ios") }
    assert_match(/has no platform variant/, error.message)
    assert_match(/varies by: market/, error.message)
  end

  def test_a_dimension_value_outside_its_enum_raises
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps.for(market: "ZA") }
    assert_match(/"ZA" is not a valid market/, error.message)
  end

  def test_a_dial_without_variants_takes_no_scope
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.signups_enabled.for(market: "KE") }
    assert_match(/declares no variants/, error.message)
  end

  def test_scope_spelling_does_not_create_a_second_override
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)
    Dials.checkout_fee_bps.set(130, "market" => "BD", :actor => OPS)

    assert_equal 130, Dials.checkout_fee_bps.for(market: "BD")
    assert_equal 1, Dials.checkout_fee_bps.overrides.size
  end

  def test_a_dial_can_list_its_own_overrides
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(300, actor: OPS)
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)

    assert_equal({ {} => 300, { market: "BD" } => 120 }, Dials.checkout_fee_bps.overrides)
    assert_empty Dials.signups_enabled.overrides
  end
end

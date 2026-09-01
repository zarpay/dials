# frozen_string_literal: true

require "test_helper"

class ReadingTest < DialsTest
  def test_an_unset_dial_reads_its_code_default
    declare_fee_and_switch

    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
    assert_equal 250, Dials.checkout_fee_bps
    assert_equal true, Dials.signups_enabled
  end

  def test_a_global_override_beats_the_default_everywhere
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)

    assert_equal 300, Dials.checkout_fee_bps(market: "KE")
    assert_equal 300, Dials.checkout_fee_bps(market: "BD")
    assert_equal 300, Dials.checkout_fee_bps
  end

  def test_a_scoped_override_beats_the_global_only_in_its_own_scope
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
    assert_equal 300, Dials.checkout_fee_bps(market: "KE")
    assert_equal 300, Dials.checkout_fee_bps
  end

  def test_the_example_from_the_readme
    declare_fee_and_switch

    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)
    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
    assert_equal 250, Dials.checkout_fee_bps(market: "KE")
  end

  def test_the_most_specific_stored_scope_wins
    Dials.define do
      dial :fee, default: 250, type: Integer,
           dimensions: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.adjust(:fee, 300, actor: OPS)
    Dials.adjust(:fee, 200, market: "BD", actor: OPS)
    Dials.adjust(:fee, 100, market: "BD", platform: "ios", actor: OPS)

    assert_equal 100, Dials.fee(market: "BD", platform: "ios")
    assert_equal 200, Dials.fee(market: "BD", platform: "android")
    assert_equal 300, Dials.fee(market: "KE", platform: "ios")
  end

  def test_a_partial_scope_covers_every_dimension_it_does_not_name
    Dials.define do
      dial :fee, default: 250, type: Integer,
           dimensions: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.adjust(:fee, 150, platform: "ios", actor: OPS)

    assert_equal 150, Dials.fee(market: "KE", platform: "ios")
    assert_equal 150, Dials.fee(market: "BD", platform: "ios")
    assert_equal 250, Dials.fee(market: "BD", platform: "android")
  end

  def test_equally_specific_scopes_are_broken_by_declaration_order
    Dials.define do
      dial :fee, default: 250, type: Integer,
           dimensions: { market: %w[KE BD], platform: %w[ios android] }
    end

    Dials.adjust(:fee, 111, market: "BD", actor: OPS)
    Dials.adjust(:fee, 222, platform: "ios", actor: OPS)

    # Both match; market is declared first, so market wins.
    assert_equal 111, Dials.fee(market: "BD", platform: "ios")
  end

  def test_a_scope_naming_a_dimension_the_dial_does_not_have_raises
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps(platform: "ios") }
    assert_match(/has no platform dimension/, error.message)
    assert_match(/varies by: market/, error.message)
  end

  def test_a_dimension_value_outside_its_enum_raises
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps(market: "ZA") }
    assert_match(/"ZA" is not a valid market/, error.message)
  end

  def test_an_empty_dimension_value_raises_rather_than_reading_the_global
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)

    # `market: params[:market]` with a missing param arrives as "". Answering
    # with the global would be a wrong answer delivered quietly.
    error = assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps(market: nil) }
    assert_match(/market is empty/, error.message)
    assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps(market: "") }
  end

  def test_an_overlong_dimension_value_raises
    Dials.define { dial :fee, default: 1, type: Integer, dimensions: { market: String } }

    assert_raises(Dials::InvalidScope) { Dials.fee(market: "x" * 129) }
    assert_equal 1, Dials.fee(market: "x" * 128)
  end

  def test_a_dial_without_dimensions_takes_no_scope
    declare_fee_and_switch

    error = assert_raises(Dials::InvalidScope) { Dials.signups_enabled(market: "KE") }
    assert_match(/declares no dimensions/, error.message)
  end

  def test_scope_spelling_does_not_create_a_second_override
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)
    Dials.adjust(:checkout_fee_bps, 130, "market" => "BD", :actor => OPS)

    assert_equal 130, Dials.checkout_fee_bps(market: "BD")
    assert_equal 1, Dials[:checkout_fee_bps].overrides.size
  end

  def test_the_catalog_reads_every_dial_from_one_snapshot
    Dials.cache_ttl = 0 # rebuild on every read, the worst case for tearing
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)
    Dials.adjust(:signups_enabled, false, actor: OPS)

    pairs = Dials.catalog

    assert_equal %i[checkout_fee_bps signups_enabled], pairs.map { |dial, _| dial.key }
    assert_equal({ {} => 300 }, pairs.first.last)
    assert_equal({ {} => false }, pairs.last.last)

    # One snapshot means one query, however many dials are listed.
    assert_equal 1, count_queries { Dials.catalog }.size
  end

  def test_a_dial_can_list_its_own_overrides
    declare_fee_and_switch
    Dials.adjust(:checkout_fee_bps, 300, actor: OPS)
    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

    assert_equal({ {} => 300, { market: "BD" } => 120 }, Dials[:checkout_fee_bps].overrides)
    assert_empty Dials[:signups_enabled].overrides
  end
end

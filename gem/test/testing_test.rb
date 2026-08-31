# frozen_string_literal: true

require "test_helper"

class TestingTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def test_override_applies_for_every_scope_of_the_dial
    Dials::Testing.with_overrides(merchant_fee_bps: 250) do
      assert_equal 250, Dials.get(:merchant_fee_bps, market: "KE")
      assert_equal 250, Dials.get(:merchant_fee_bps, market: "NG")
    end
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_override_can_pin_false
    Dials::Testing.with_overrides(signups_enabled: false) do
      assert_equal false, Dials.get(:signups_enabled)
    end
  end

  def test_overrides_nest_and_restore
    Dials::Testing.with_overrides(merchant_fee_bps: 250) do
      Dials::Testing.with_overrides(merchant_fee_bps: 300) do
        assert_equal 300, Dials.get(:merchant_fee_bps, market: "KE")
      end
      assert_equal 250, Dials.get(:merchant_fee_bps, market: "KE")
    end
  end

  def test_override_values_are_validated
    assert_raises(Dials::InvalidValue) do
      Dials::Testing.with_overrides(merchant_fee_bps: "cheap") { nil }
    end
  end

  def test_override_of_unknown_dial_raises
    assert_raises(Dials::UnknownDial) do
      Dials::Testing.with_overrides(merchant_fee: 1) { nil }
    end
  end

  def test_invalid_reads_still_raise_under_override
    Dials::Testing.with_overrides(merchant_fee_bps: 250) do
      assert_raises(Dials::InvalidScope) { Dials.get(:merchant_fee_bps) }
      assert_raises(Dials::InvalidScope) { Dials.get(:merchant_fee_bps, market: "US") }
    end
  end

  def test_overrides_do_not_touch_store_or_change_log
    Dials::Testing.with_overrides(merchant_fee_bps: 250) { Dials.get(:merchant_fee_bps, market: "KE") }
    assert_empty Dials.changes
  end
end

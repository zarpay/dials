# frozen_string_literal: true

require "test_helper"

class StubbingTest < DialsTest
  def test_a_stub_pins_a_dial_for_every_scope_inside_the_block
    declare_fee_and_switch

    Dials.stub(checkout_fee_bps: 999) do
      assert_equal 999, Dials.checkout_fee_bps.for(market: "KE")
      assert_equal 999, Dials.checkout_fee_bps.for(market: "BD")
      assert_equal 999, Dials.checkout_fee_bps.for
    end

    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
  end

  def test_a_stub_beats_a_stored_override_without_touching_it
    declare_fee_and_switch
    Dials.checkout_fee_bps.set(120, market: "BD", actor: OPS)

    Dials.stub(checkout_fee_bps: 999) do
      assert_equal 999, Dials.checkout_fee_bps.for(market: "BD")
    end

    assert_equal 120, Dials.checkout_fee_bps.for(market: "BD")
    assert_equal 1, Dials::Record.count
  end

  def test_stubs_nest_and_the_inner_one_wins
    declare_fee_and_switch

    Dials.stub(checkout_fee_bps: 111) do
      Dials.stub(signups_enabled: false) do
        assert_equal 111, Dials.checkout_fee_bps.for(market: "KE")
        assert_equal false, Dials.signups_enabled.value

        Dials.stub(checkout_fee_bps: 222) do
          assert_equal 222, Dials.checkout_fee_bps.for(market: "KE")
        end

        assert_equal 111, Dials.checkout_fee_bps.for(market: "KE")
      end

      assert_equal true, Dials.signups_enabled.value
    end
  end

  def test_a_stub_is_validated_so_a_test_cannot_pin_the_impossible
    declare_fee_and_switch

    assert_raises(Dials::InvalidValue) { Dials.stub(checkout_fee_bps: 0) { flunk } }
    assert_raises(Dials::UnknownDial) { Dials.stub(nope: 1) { flunk } }
  end

  def test_a_stub_unwinds_even_when_the_block_raises
    declare_fee_and_switch

    assert_raises(RuntimeError) { Dials.stub(checkout_fee_bps: 999) { raise "boom" } }
    assert_equal 250, Dials.checkout_fee_bps.for(market: "KE")
  end

  def test_a_stub_cannot_hide_a_scope_bug
    declare_fee_and_switch

    Dials.stub(checkout_fee_bps: 999) do
      assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps.for(market: "ZA") }
      assert_raises(Dials::InvalidScope) { Dials.checkout_fee_bps.for(platform: "ios") }
    end
  end
end

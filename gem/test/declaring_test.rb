# frozen_string_literal: true

require "test_helper"

class DeclaringTest < DialsTest
  def test_a_declared_dial_is_reachable_by_name_and_by_key
    declare_fee_and_switch

    assert_kind_of Dials::Dial, Dials.checkout_fee_bps
    assert_same Dials.checkout_fee_bps, Dials[:checkout_fee_bps]
    assert_same Dials.checkout_fee_bps, Dials["checkout_fee_bps"]
    assert_equal :checkout_fee_bps, Dials.checkout_fee_bps.key
  end

  def test_the_catalog_lists_every_dial
    declare_fee_and_switch

    assert_equal %i[checkout_fee_bps signups_enabled], Dials.all.map(&:key)
    assert_equal %i[checkout_fee_bps signups_enabled], Dials.each.to_a.map(&:key)
  end

  def test_declarations_accumulate_across_blocks
    Dials.define { dial :a, default: 1, type: Integer }
    Dials.define { dial :b, default: 2, type: Integer }

    assert_equal %i[a b], Dials.all.map(&:key)
  end

  def test_a_dial_carries_its_presentation_metadata
    declare_fee_and_switch
    fee = Dials.checkout_fee_bps

    assert_equal "Checkout fee bps", fee.label
    assert_equal "bps", fee.unit
    assert_equal "Fee charged at checkout.", fee.description
    assert_equal %i[market], fee.variants.keys
    assert_predicate fee, :variants?
    refute_predicate Dials.signups_enabled, :variants?
  end

  def test_asking_for_a_dial_that_does_not_exist_says_what_does
    declare_fee_and_switch

    error = assert_raises(Dials::UnknownDial) { Dials[:nope] }
    assert_match(/no dial named :nope/, error.message)
    assert_match(/checkout_fee_bps/, error.message)
  end

  def test_declaring_the_same_key_twice_raises
    Dials.define { dial :a, default: 1, type: Integer }

    error = assert_raises(Dials::InvalidDial) { Dials.define { dial :a, default: 2, type: Integer } }
    assert_match(/already declared/, error.message)
  end

  def test_a_key_that_would_shadow_the_api_raises
    error = assert_raises(Dials::InvalidDial) { Dials.define { dial :reload!, default: 1, type: Integer } }
    assert_match(/already exists/, error.message)
  end

  def test_a_default_that_fails_its_own_type_raises_at_declaration
    error = assert_raises(Dials::InvalidDial) do
      Dials.define { dial :fee, default: 0, type: _Integer(1..10) }
    end
    assert_match(/dial fee/, error.message)
    assert_match(/\b0\b/, error.message)
  end

  def test_a_symbol_type_is_called_out_rather_than_silently_failing
    error = assert_raises(Dials::InvalidDial) do
      Dials.define { dial :fee, default: 1, type: :integer }
    end
    assert_match(/is not a type/, error.message)
  end

  def test_types_can_be_plain_ruby_or_literal_or_an_array
    Dials.define do
      dial :plain,   default: 1,     type: Integer
      dial :ranged,  default: 5,     type: 1..10
      dial :enumed,  default: "low", type: %w[low high]
      dial :literal, default: "abc", type: _String(/\A[a-z]+\z/)
      dial :blob,    default: { "a" => [1, 2] }, type: _JSONData
    end

    assert_equal 1, Dials.plain.value
    assert_equal({ "a" => [1, 2] }, Dials.blob.value)
    assert_raises(Dials::InvalidValue) { Dials.enumed.set("medium", actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.literal.set("ABC", actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.ranged.set(11, actor: OPS) }
  end

  def test_a_dial_inspects_readably
    declare_fee_and_switch

    assert_equal "#<Dials::Dial checkout_fee_bps default=250 type=_Constraint(Integer, 1..10000) variants=[:market]>",
                 Dials.checkout_fee_bps.inspect
  end

  def test_the_default_is_frozen_so_one_caller_cannot_corrupt_every_other
    Dials.define { dial :blob, default: { "a" => [1] }, type: _JSONData }

    assert_raises(FrozenError) { Dials.blob.value["a"] << 2 }
  end
end

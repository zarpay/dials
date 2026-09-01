# frozen_string_literal: true

require "test_helper"

class DeclaringTest < DialsTest
  def test_the_generated_reader_returns_the_value_and_never_an_object
    declare_fee_and_switch

    assert_equal 250, Dials.checkout_fee_bps
    assert_instance_of Integer, Dials.checkout_fee_bps(market: "KE")
    assert_instance_of TrueClass, Dials.signups_enabled
  end

  def test_a_kill_switch_that_is_off_is_falsy_at_the_call_site
    declare_fee_and_switch
    Dials.adjust(:signups_enabled, false, actor: OPS)

    # The reason readers return primitives: any object standing in for `false`
    # would be truthy here, and a kill switch you had turned off would read as
    # on. There is no way to make a non-primitive falsy in Ruby, so the only
    # fix is not to hand one out.
    refute Dials.signups_enabled
    assert_instance_of FalseClass, Dials.signups_enabled
  end

  def test_the_dial_itself_is_reachable_but_only_by_asking_for_it
    declare_fee_and_switch

    assert_kind_of Dials::Dial, Dials[:checkout_fee_bps]
    assert_same Dials[:checkout_fee_bps], Dials["checkout_fee_bps"]
    assert_equal :checkout_fee_bps, Dials[:checkout_fee_bps].key
    assert_equal 250, Dials[:checkout_fee_bps].default
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
    fee = Dials[:checkout_fee_bps]

    assert_equal "Checkout fee bps", fee.label
    assert_equal "bps", fee.unit
    assert_equal "Fee charged at checkout.", fee.description
    assert_equal %i[market], fee.dimensions.keys
    assert_predicate fee, :dimensions?
    refute_predicate Dials[:signups_enabled], :dimensions?
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
    error = assert_raises(Dials::InvalidDial) { Dials.define { dial :adjust, default: 1, type: Integer } }
    assert_match(/already exists/, error.message)
  end

  def test_a_dimension_cannot_be_named_after_a_write_keyword
    # It would be unreachable, and silently so: the write methods take actor:
    # and if_unchanged_since: as their own, so the scope would arrive empty and
    # the write would target the global instead of raising.
    %i[actor if_unchanged_since].each do |name|
      error = assert_raises(Dials::InvalidDial) do
        Dials.define { dial :"fee_#{name}", default: 1, type: Integer, dimensions: { name => %w[a b] } }
      end
      assert_match(/cannot be a dimension name/, error.message)
    end
  end

  def test_an_overlong_key_raises_at_declaration_rather_than_at_the_column
    error = assert_raises(Dials::InvalidDial) do
      Dials.define { dial :"#{'k' * 101}", default: 1, type: Integer }
    end
    assert_match(/key is longer than 100 characters/, error.message)

    Dials.define { dial :"#{'k' * 100}", default: 1, type: Integer }
    assert_equal 1, Dials.all.size
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

    assert_equal 1, Dials.plain
    assert_equal({ "a" => [1, 2] }, Dials.blob)
    assert_raises(Dials::InvalidValue) { Dials.adjust(:enumed, "medium", actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.adjust(:literal, "ABC", actor: OPS) }
    assert_raises(Dials::InvalidValue) { Dials.adjust(:ranged, 11, actor: OPS) }
  end

  def test_a_dial_inspects_readably
    declare_fee_and_switch

    assert_equal "#<Dials::Dial checkout_fee_bps default=250 type=_Constraint(Integer, 1..10000) dimensions=[:market]>",
                 Dials[:checkout_fee_bps].inspect
  end

  def test_the_default_is_frozen_so_one_caller_cannot_corrupt_every_other
    Dials.define { dial :blob, default: { "a" => [1] }, type: _JSONData }

    assert_raises(FrozenError) { Dials.blob["a"] << 2 }
  end
end

# frozen_string_literal: true

require "test_helper"

class DefinitionTest < Minitest::Test
  include DialsTestSupport

  def build(key = :fee, default = 10, **)
    Dials::Definition.new(key, default, type: :integer, **)
  end

  def test_valid_types
    assert_equal :boolean, build(:a, true, type: :boolean).type
    assert_equal :integer, build(:b, 1, type: :integer).type
    assert_equal :float, build(:c, 1.5, type: :float).type
    assert_equal :string, build(:d, "x", type: :string).type
    assert_equal :json, build(:e, { "a" => 1 }, type: :json).type
  end

  def test_unknown_type_raises
    assert_raises(Dials::InvalidDefinition) { build(type: :decimal) }
  end

  def test_default_must_satisfy_own_rules
    assert_raises(Dials::InvalidDefinition) { build(:fee, "ten", type: :integer) }
    assert_raises(Dials::InvalidDefinition) { build(:fee, 0, type: :integer, bounds: 1..100) }
    assert_raises(Dials::InvalidDefinition) { build(:fee, nil, type: :integer) }
  end

  def test_false_is_a_storable_boolean
    definition = build(:kill_switch, true, type: :boolean)
    assert_equal false, definition.validate_value!(false)
  end

  def test_false_is_a_storable_default
    definition = build(:kill_switch, false, type: :boolean)
    assert_equal false, definition.default
  end

  def test_nil_is_never_storable
    definition = build
    error = assert_raises(Dials::InvalidValue) { definition.validate_value!(nil) }
    assert_match(/clear/, error.message)
  end

  def test_type_mismatches_rejected
    assert_raises(Dials::InvalidValue) { build(:a, true, type: :boolean).validate_value!("true") }
    assert_raises(Dials::InvalidValue) { build(:b, 1, type: :integer).validate_value!(1.5) }
    assert_raises(Dials::InvalidValue) { build(:d, "x", type: :string).validate_value!(:x) }
  end

  def test_float_accepts_integers
    assert_equal 3, build(:c, 1.5, type: :float).validate_value!(3)
  end

  def test_range_bounds
    definition = build(bounds: 1..100)
    assert_equal 100, definition.validate_value!(100)
    assert_raises(Dials::InvalidValue) { definition.validate_value!(101) }
  end

  def test_array_bounds
    definition = build(:mode, "slow", type: :string, bounds: %w[slow fast])
    assert_equal "fast", definition.validate_value!("fast")
    assert_raises(Dials::InvalidValue) { definition.validate_value!("medium") }
  end

  def test_callable_bounds
    definition = build(bounds: lambda(&:even?))
    assert_equal 4, definition.validate_value!(4)
    assert_raises(Dials::InvalidValue) { definition.validate_value!(3) }
  end

  def test_bad_bounds_shape_raises
    assert_raises(Dials::InvalidDefinition) { build(bounds: "1-100") }
  end

  def test_default_label_from_key
    assert_equal "Merchant fee bps", build(:merchant_fee_bps).label
  end

  def test_variants_hash_with_options
    definition = build(variants: { market: { options: %w[KE NG] } })
    assert definition.variants?
    assert_equal [:market], definition.dimension_names
    assert_equal %w[KE NG], definition.dimensions.first.options
  end

  def test_variants_shorthand_array_of_names
    definition = build(variants: %i[market platform])
    assert_equal %i[market platform], definition.dimension_names
    assert_nil definition.dimensions.first.options
  end

  def test_variants_shorthand_options_array
    definition = build(variants: { market: %w[KE NG] })
    assert_equal %w[KE NG], definition.dimensions.first.options
  end

  def test_variants_callable_options_resolved_lazily
    calls = 0
    definition = build(variants: { market: { options: lambda {
      calls += 1
      %w[KE]
    } } })
    assert_equal 0, calls
    assert definition.dimensions.first.valid_value?("KE")
    assert definition.dimensions.first.valid_value?(:KE)
    refute definition.dimensions.first.valid_value?("US")
    assert_equal 1, calls
  end

  def test_duplicate_dimension_raises
    assert_raises(Dials::InvalidDefinition) { build(variants: [:market, "market"]) }
  end

  def test_definitions_are_frozen
    assert build.frozen?
  end
end

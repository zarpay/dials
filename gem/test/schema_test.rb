# frozen_string_literal: true

require "test_helper"

class SchemaTest < Minitest::Test
  include DialsTestSupport

  def build(key = :fee, default = 10, type: :integer, **)
    Dials::Definition.new(key, default: default, type: type, **)
  end

  # -- numeric keywords -------------------------------------------------------

  def test_minimum_and_maximum_are_inclusive
    definition = build(minimum: 1, maximum: 100)
    assert_equal 1, definition.validate_value!(1)
    assert_equal 100, definition.validate_value!(100)
    assert_match(/must be >= 1/, invalid(definition, 0))
    assert_match(/must be <= 100/, invalid(definition, 101))
  end

  def test_exclusive_bounds
    definition = build(:ratio, 0.5, type: :float, exclusive_minimum: 0, exclusive_maximum: 1)
    assert_match(/must be > 0/, invalid(definition, 0))
    assert_match(/must be < 1/, invalid(definition, 1.0))
    assert_equal 0.01, definition.validate_value!(0.01)
  end

  def test_multiple_of
    definition = build(minimum: 0, multiple_of: 5)
    assert_equal 15, definition.validate_value!(15)
    assert_match(/must be a multiple of 5/, invalid(definition, 12))
  end

  def test_violations_accumulate
    definition = build(:fee, 20, minimum: 20, multiple_of: 5)
    message = invalid(definition, 12)
    assert_match(/must be >= 20/, message)
    assert_match(/must be a multiple of 5/, message)
  end

  # -- string keywords --------------------------------------------------------

  def test_length_keywords
    definition = build(:code, "abc", type: :string, min_length: 2, max_length: 5)
    assert_equal "ab", definition.validate_value!("ab")
    assert_match(/at least 2 characters/, invalid(definition, "a"))
    assert_match(/at most 5 characters/, invalid(definition, "abcdef"))
  end

  def test_pattern_accepts_regexp_or_string
    from_regexp = build(:email, "a@b.co", type: :string, pattern: /\A\S+@\S+\z/)
    from_string = build(:email2, "a@b.co", type: :string, pattern: '\A\S+@\S+\z')

    [from_regexp, from_string].each do |definition|
      assert_equal "x@y.z", definition.validate_value!("x@y.z")
      assert_match(/must match/, invalid(definition, "not an email"))
    end
  end

  def test_invalid_pattern_raises_at_boot
    assert_raises(Dials::InvalidDefinition) { build(:email, "a@b.co", type: :string, pattern: "[unclosed") }
  end

  # -- enum ------------------------------------------------------------------

  def test_enum_on_any_type
    definition = build(:tier, "low", type: :string, enum: %w[low medium high])
    assert_equal "high", definition.validate_value!("high")
    assert_match(/must be one of/, invalid(definition, "extreme"))
  end

  # -- :json object schemas ---------------------------------------------------

  def banner(**)
    build(:banner, { "headline" => "Hi", "cta" => "Go" }, type: :json,
                   properties: { "headline" => { type: :string, min_length: 1 },
                                 "cta" => { type: :string } },
                   required: %w[headline cta], **)
  end

  def test_required_keys_enforced
    assert_match(/missing required key "cta"/, invalid(banner, { "headline" => "Hi" }))
  end

  def test_property_schemas_enforced_with_paths
    message = invalid(banner, { "headline" => 5, "cta" => "Go" })
    assert_match(/headline must be a string/, message)

    message = invalid(banner, { "headline" => "", "cta" => "Go" })
    assert_match(/headline must be at least 1 characters/, message)
  end

  def test_undeclared_keys_are_allowed
    value = { "headline" => "Hi", "cta" => "Go", "extra" => 1 }
    assert_equal value, banner.validate_value!(value)
  end

  def test_declaring_properties_pins_the_dial_to_objects
    assert_match(/must be a JSON object/, invalid(banner, [1, 2]))
  end

  def test_nested_objects_and_arrays
    definition = build(:config, { "tags" => %w[a], "meta" => { "level" => 1 } }, type: :json,
                                properties: {
                                  "tags" => { type: :array, items: { type: :string, max_length: 3 } },
                                  "meta" => { type: :object, properties: { "level" => { type: :integer, minimum: 0 } } }
                                })
    message = invalid(definition, { "tags" => ["fine", "toolong"], "meta" => { "level" => -1 } })
    assert_match(/tags\[1\] must be at most 3 characters/, message)
    assert_match(/meta\.level must be >= 0/, message)
  end

  def test_json_without_object_keywords_still_accepts_any_json
    definition = build(:blob, [1, 2], type: :json)
    assert_equal({ "a" => 1 }, definition.validate_value!({ "a" => 1 }))
    assert_equal false, definition.validate_value!(false)
  end

  # -- boot-time strictness ---------------------------------------------------

  def test_keywords_must_apply_to_the_type
    error = assert_raises(Dials::InvalidDefinition) { build(:fee, 10, type: :integer, pattern: /x/) }
    assert_match(/unknown keyword pattern/, error.message)
    assert_raises(Dials::InvalidDefinition) { build(:name, "x", type: :string, minimum: 1) }
    assert_raises(Dials::InvalidDefinition) { build(:flag, true, type: :boolean, maximum: 1) }
  end

  def test_nested_schemas_require_a_type
    error = assert_raises(Dials::InvalidDefinition) do
      build(:j, { "a" => 1 }, type: :json, properties: { "a" => { minimum: 0 } })
    end
    assert_match(/needs a type/, error.message)
  end

  def test_keyword_shapes_checked_at_boot
    assert_raises(Dials::InvalidDefinition) { build(minimum: "1") }
    assert_raises(Dials::InvalidDefinition) { build(multiple_of: 0) }
    assert_raises(Dials::InvalidDefinition) { build(enum: []) }
    assert_raises(Dials::InvalidDefinition) { build(:s, "x", type: :string, min_length: -1) }
    assert_raises(Dials::InvalidDefinition) { build(:j, {}, type: :json, required: "cta") }
  end

  def test_default_must_satisfy_the_schema
    assert_raises(Dials::InvalidDefinition) { build(:fee, 0, minimum: 1) }
  end

  # -- serialization ----------------------------------------------------------

  def test_to_json_schema_uses_camel_case_keywords
    definition = build(:fee, 10, minimum: 1, maximum: 100, multiple_of: 5,
                                 description: "A fee.", unit: "bps")
    assert_equal(
      { "type" => "integer", "title" => "Fee", "description" => "A fee.",
        "minimum" => 1, "maximum" => 100, "multipleOf" => 5, "default" => 10 },
      definition.to_json_schema
    )
  end

  def test_to_json_schema_for_strings_and_json_objects
    email = build(:email, "a@b.co", type: :string, max_length: 64, pattern: /\A\S+@\S+\z/)
    schema = email.to_json_schema
    assert_equal "string", schema["type"]
    assert_equal 64, schema["maxLength"]
    assert_equal '\A\S+@\S+\z', schema["pattern"]

    schema = banner.to_json_schema
    assert_equal "object", schema["type"]
    assert_equal %w[headline cta], schema["required"]
    assert_equal({ "type" => "string", "minLength" => 1 }, schema["properties"]["headline"])
  end

  def test_float_maps_to_number_and_unconstrained_json_has_no_type
    assert_equal "number", build(:r, 0.5, type: :float).to_json_schema["type"]
    refute build(:blob, [1], type: :json).to_json_schema.key?("type")
  end

  private

  def invalid(definition, value)
    assert_raises(Dials::InvalidValue) { definition.validate_value!(value) }.message
  end
end

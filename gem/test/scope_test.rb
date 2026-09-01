# frozen_string_literal: true

require "test_helper"

class ScopeTest < Minitest::Test
  include DialsTestSupport

  def multi
    @multi ||= Dials::Definition.new(:d, default: 1, type: :integer,
                                          variants: { market: %w[KE NG], platform: %w[ios web] })
  end

  def test_canonical_is_deterministic_across_spellings
    a = Dials::Scope.canonical({ platform: "ios", market: "KE" })
    b = Dials::Scope.canonical({ "market" => :KE, "platform" => :ios })
    assert_equal a, b
    assert_equal '{"market":"KE","platform":"ios"}', a
  end

  def test_parse_inverts_canonical
    canonical = Dials::Scope.canonical({ market: "KE" })
    assert_equal({ market: "KE" }, Dials::Scope.parse(canonical))
  end

  def test_parse_rejects_json_that_is_not_an_object
    assert_raises(Dials::InvalidScope) { Dials::Scope.parse("42") }
    assert_raises(Dials::InvalidScope) { Dials::Scope.parse("[]") }
  end

  def test_exact_requires_every_dimension
    error = assert_raises(Dials::InvalidScope) do
      Dials::Scope.validate!(multi, { market: "KE" }, exact: true)
    end
    assert_match(/platform/, error.message)
  end

  def test_exact_accepts_full_scope_and_normalizes
    normalized = Dials::Scope.validate!(multi, { market: :KE, "platform" => "ios" }, exact: true)
    assert_equal({ market: "KE", platform: "ios" }, normalized)
  end

  def test_unknown_dimension_rejected
    assert_raises(Dials::InvalidScope) do
      Dials::Scope.validate!(multi, { market: "KE", platform: "ios", region: "east" }, exact: true)
    end
  end

  def test_value_outside_options_rejected
    assert_raises(Dials::InvalidScope) do
      Dials::Scope.validate!(multi, { market: "US", platform: "ios" }, exact: true)
    end
  end

  def test_scope_on_variantless_dial_rejected
    plain = Dials::Definition.new(:p, default: 1, type: :integer)
    assert_raises(Dials::InvalidScope) do
      Dials::Scope.validate!(plain, { market: "KE" }, exact: true)
    end
    assert_equal({}, Dials::Scope.validate!(plain, {}, exact: true))
  end

  def test_subset_allowed_when_not_exact
    normalized = Dials::Scope.validate!(multi, { market: "KE" }, exact: false)
    assert_equal({ market: "KE" }, normalized)
  end

  def test_open_dimension_accepts_any_nonempty_value
    open = Dials::Definition.new(:o, default: 1, type: :integer, variants: [:tenant])
    assert_equal({ tenant: "acme" }, Dials::Scope.validate!(open, { tenant: "acme" }, exact: true))
    assert_raises(Dials::InvalidScope) { Dials::Scope.validate!(open, { tenant: "" }, exact: true) }
  end

  def test_open_dimension_values_are_length_capped
    open = Dials::Definition.new(:o, default: 1, type: :integer, variants: [:tenant])
    at_limit = "a" * Dials::Dimension::MAX_VALUE_LENGTH
    assert_equal({ tenant: at_limit }, Dials::Scope.validate!(open, { tenant: at_limit }, exact: true))
    assert_raises(Dials::InvalidScope) do
      Dials::Scope.validate!(open, { tenant: "#{at_limit}x" }, exact: true)
    end
  end

  def test_canonical_scope_is_byte_capped_for_the_indexed_column
    two_dims = Dials::Definition.new(:t, default: 1, type: :integer, variants: %i[tenant region])
    long = "a" * Dials::Dimension::MAX_VALUE_LENGTH
    scope = Dials::Scope.validate!(two_dims, { tenant: long, region: long }, exact: true)
    error = assert_raises(Dials::InvalidScope) { Dials::Scope.canonical(scope) }
    assert_match(/exceeds 255 bytes/, error.message)
  end

  def test_conflicting_key_spellings_raise
    error = assert_raises(Dials::InvalidScope) do
      Dials::Scope.normalize({ "market" => "KE", market: "NG" })
    end
    assert_match(/more than once/, error.message)
  end
end

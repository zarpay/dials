# frozen_string_literal: true

require "test_helper"

class RegistryTest < Minitest::Test
  include DialsTestSupport

  def test_define_and_fetch
    define_standard_dials
    definition = Dials.registry.fetch(:merchant_fee_bps)
    assert_equal 100, definition.default
    assert_equal definition, Dials.registry.fetch("merchant_fee_bps")
  end

  def test_unknown_key_raises_with_known_keys_listed
    define_standard_dials
    error = assert_raises(Dials::UnknownDial) { Dials.registry.fetch(:merchant_fee) }
    assert_match(/merchant_fee_bps/, error.message)
  end

  def test_duplicate_key_raises
    define_standard_dials
    assert_raises(Dials::DuplicateDial) do
      Dials.define { dial :signups_enabled, false, type: :boolean }
    end
  end

  def test_declarations_accumulate_across_define_blocks
    Dials.define { dial :a, 1, type: :integer }
    Dials.define { dial :b, 2, type: :integer }
    assert_equal %i[a b], Dials.registry.keys
  end

  def test_enumerable
    define_standard_dials
    assert_equal 4, Dials.registry.count
    assert(Dials.registry.any? { |d| d.key == :signups_enabled })
  end

  def test_reset
    define_standard_dials
    Dials.registry.reset!
    assert_empty Dials.registry.keys
  end
end

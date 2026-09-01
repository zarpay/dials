# frozen_string_literal: true

require "test_helper"

# Compare-and-swap writes (expected_version:) against the memory store.
# ActiveRecord-specific semantics (transactionality, the lock anchor, retry
# behavior) are covered in active_record_store_test.rb.
class CasTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def test_write_at_the_current_version_succeeds_and_returns_the_new_token
    version = Dials.overview.version
    token = Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: version)

    assert_equal 200, Dials.use_merchant_fee_bps(market: "KE")
    assert_kind_of String, token
    refute_equal version, token
    assert_equal Dials.overview.version, token
  end

  def test_tokens_chain_across_sequential_writes
    token = Dials.overview.version
    token = Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: token)
    token = Dials.adjust_merchant_fee_bps(300, actor: ACTOR, expected_version: token)
    Dials.clear_merchant_fee_bps(actor: ACTOR, expected_version: token)

    assert_equal 100, Dials.use_merchant_fee_bps(market: "KE") # back to the default
  end

  def test_stale_write_raises_with_nothing_applied_and_nothing_logged
    version = Dials.overview.version
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR) # someone else moves the store

    changes_before = Dials.changes.length
    assert_raises(Dials::StaleWrite) do
      Dials.adjust_merchant_fee_bps(999, actor: ACTOR, expected_version: version)
    end

    assert_equal 200, Dials.use_merchant_fee_bps(market: "KE")
    assert_equal changes_before, Dials.changes.length
  end

  def test_stale_clear_raises_even_when_it_would_be_a_noop
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    version = Dials.overview.version
    Dials.clear_merchant_fee_bps(actor: ACTOR) # someone else clears it first

    # The page showed an override that no longer exists — the picture IS
    # stale, so the no-op clear must refuse rather than silently "succeed".
    assert_raises(Dials::StaleWrite) do
      Dials.clear_merchant_fee_bps(actor: ACTOR, expected_version: version)
    end
  end

  def test_nil_expected_version_keeps_unconditional_last_write_wins
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    assert_equal 300, Dials.adjust_merchant_fee_bps(300, actor: ACTOR) # returns the value, as always
    assert_equal true, Dials.clear_merchant_fee_bps(actor: ACTOR)      # returns the boolean, as always
  end

  def test_two_racing_writers_with_the_same_token_produce_exactly_one_winner
    version = Dials.overview.version
    barrier = Queue.new
    results = Array.new(2)

    threads = 2.times.map do |i|
      Thread.new do
        barrier.pop
        results[i] =
          begin
            Dials.adjust_merchant_fee_bps(200 + i, actor: ACTOR, expected_version: version)
            :won
          rescue Dials::StaleWrite
            :stale
          end
      end
    end
    2.times { barrier << true }
    threads.each(&:join)

    assert_equal %i[stale won], results.sort
    assert_equal 1, Dials.changes.length
  end

  def test_cas_works_through_the_primitives_too
    version = Dials.overview.version
    Dials.set(:merchant_fee_bps, 200, actor: ACTOR, expected_version: version,
                                      scope: { market: "BD" })
    assert_equal 200, Dials.use_merchant_fee_bps(market: "BD")

    assert_raises(Dials::StaleWrite) do
      Dials.clear(:merchant_fee_bps, actor: ACTOR, scope: { market: "BD" }, expected_version: version)
    end
  end

  def test_expected_version_is_a_reserved_dimension_name
    error = assert_raises(Dials::InvalidDefinition) do
      Dials.define { dial :fee, default: 1, type: :integer, variants: { expected_version: %w[a] } }
    end
    assert_match(/expected_version is a reserved dimension name/, error.message)
  end
end

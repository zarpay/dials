# frozen_string_literal: true

require "test_helper"

# Compare-and-swap writes (expected_version:) against the memory store.
# Tokens are PER OVERRIDE: the global's and each scoped override's version travel
# on Dials.overview's DialStates, and Dials::ABSENT_VERSION asserts "no
# override was stored here when I looked". ActiveRecord-specific semantics
# (transactionality, guarded statements, retry behavior) are covered in
# active_record_store_test.rb.
class CasTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def state_of(key)
    Dials.overview.dials.find { |d| d.key == key }
  end

  def test_write_against_an_absent_override_with_the_absent_token
    token = Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)

    assert_equal 200, Dials.merchant_fee_bps(market: "KE")
    assert_kind_of String, token
    refute_equal Dials::ABSENT_VERSION, token
    assert_equal state_of(:merchant_fee_bps).global_version, token
  end

  def test_tokens_chain_across_sequential_writes_to_one_override
    token = Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)
    token = Dials.adjust_merchant_fee_bps(300, actor: ACTOR, expected_version: token)
    token = Dials.clear_merchant_fee_bps(actor: ACTOR, expected_version: token)

    assert_equal Dials::ABSENT_VERSION, token, "a CAS clear returns the absent token — the row is gone"
    assert_equal 100, Dials.merchant_fee_bps(market: "KE") # back to the default
  end

  def test_overview_carries_the_token_for_each_stored_override
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    Dials.adjust_merchant_fee_bps(120, actor: ACTOR, market: "BD")

    state = state_of(:merchant_fee_bps)
    Dials.adjust_merchant_fee_bps(90, actor: ACTOR, market: "BD",
                                  expected_version: state.scoped_override_versions[{ market: "BD" }])
    assert_equal 90, Dials.merchant_fee_bps(market: "BD")

    Dials.adjust_merchant_fee_bps(250, actor: ACTOR, expected_version: state.global_version)
    assert_equal 250, Dials.merchant_fee_bps(market: "KE")
  end

  def test_stale_write_raises_with_nothing_applied_and_nothing_logged
    Dials.adjust_merchant_fee_bps(150, actor: ACTOR)
    token = state_of(:merchant_fee_bps).global_version
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR) # someone else edits the same override

    changes_before = Dials.changes.length
    assert_raises(Dials::StaleWrite) do
      Dials.adjust_merchant_fee_bps(999, actor: ACTOR, expected_version: token)
    end

    assert_equal 200, Dials.merchant_fee_bps(market: "KE")
    assert_equal changes_before, Dials.changes.length
  end

  def test_a_write_where_the_page_saw_no_override_is_stale_once_one_appears
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR) # appears after the page rendered

    assert_raises(Dials::StaleWrite) do
      Dials.adjust_merchant_fee_bps(999, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)
    end
  end

  def test_stale_clear_raises_even_when_it_would_be_a_noop
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    token = state_of(:merchant_fee_bps).global_version
    Dials.clear_merchant_fee_bps(actor: ACTOR) # someone else clears it first

    # The page showed an override that no longer exists — the picture IS
    # stale, so the no-op clear must refuse rather than silently "succeed".
    assert_raises(Dials::StaleWrite) do
      Dials.clear_merchant_fee_bps(actor: ACTOR, expected_version: token)
    end
  end

  def test_unrelated_overrides_never_conflict
    token = Dials.adjust_merchant_fee_bps(150, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)

    # Other dials and other scopes move; this override's token stays valid.
    Dials.adjust_signups_enabled(false, actor: ACTOR)
    Dials.adjust_merchant_fee_bps(90, actor: ACTOR, market: "BD")
    Dials.adjust_free_delivery_threshold(9_000, actor: ACTOR)

    Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: token)
    assert_equal 200, Dials.merchant_fee_bps(market: "KE")
  end

  def test_nil_expected_version_keeps_unconditional_last_write_wins
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    assert_equal 300, Dials.adjust_merchant_fee_bps(300, actor: ACTOR) # returns the value, as always
    assert_equal true, Dials.clear_merchant_fee_bps(actor: ACTOR)      # returns the boolean, as always
  end

  def test_two_racing_writers_with_the_same_token_produce_exactly_one_winner
    barrier = Queue.new
    results = Array.new(2)

    threads = 2.times.map do |i|
      Thread.new do
        barrier.pop
        results[i] =
          begin
            Dials.adjust_merchant_fee_bps(200 + i, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)
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
    Dials.set(:merchant_fee_bps, 200, actor: ACTOR, expected_version: Dials::ABSENT_VERSION,
                                      scope: { market: "BD" })
    assert_equal 200, Dials.merchant_fee_bps(market: "BD")

    assert_raises(Dials::StaleWrite) do
      Dials.clear(:merchant_fee_bps, actor: ACTOR, scope: { market: "BD" },
                                     expected_version: Dials::ABSENT_VERSION)
    end
  end

  def test_expected_version_is_a_reserved_dimension_name
    error = assert_raises(Dials::InvalidDefinition) do
      Dials.define { dial :fee, default: 1, type: :integer, dimensions: { expected_version: %w[a] } }
    end
    assert_match(/expected_version is a reserved dimension name/, error.message)
  end
end

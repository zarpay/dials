# frozen_string_literal: true

require "test_helper"

class CachingTest < DialsTest
  def test_reads_do_not_hit_the_database_once_the_cache_is_warm
    Dials.cache_ttl = 60
    declare_fee_and_switch
    Dials.checkout_fee_bps(market: "KE") # warm

    queries = count_queries { 50.times { Dials.checkout_fee_bps(market: "KE") } }

    assert_empty queries
  end

  def test_a_cold_read_costs_two_queries_a_version_check_and_a_load
    Dials.cache_ttl = 60
    declare_fee_and_switch

    queries = count_queries { Dials.checkout_fee_bps(market: "KE") }

    assert_equal 2, queries.size
  end

  def test_a_stale_cache_costs_only_the_version_check
    Dials.cache_ttl = 0
    declare_fee_and_switch
    Dials.checkout_fee_bps(market: "KE") # warm

    queries = count_queries { Dials.checkout_fee_bps(market: "KE") }

    assert_equal 1, queries.size
  end

  def test_a_process_reads_its_own_write_immediately_whatever_the_ttl
    Dials.cache_ttl = 3600
    declare_fee_and_switch
    Dials.checkout_fee_bps(market: "BD") # warm

    Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_a_write_from_another_process_is_invisible_until_the_ttl_lapses
    Dials.cache_ttl = 3600
    declare_fee_and_switch
    Dials.checkout_fee_bps(market: "BD") # warm

    write_from_another_process(120)

    assert_equal 250, Dials.checkout_fee_bps(market: "BD")

    Dials.cache_ttl = 0 # as if the ttl had lapsed

    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_reload_gives_up_the_cache_on_demand
    Dials.cache_ttl = 3600
    declare_fee_and_switch
    Dials.checkout_fee_bps(market: "BD") # warm

    write_from_another_process(120)
    Dials.reload!

    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  def test_a_write_inside_a_transaction_is_visible_to_its_own_transaction
    declare_fee_and_switch

    ActiveRecord::Base.transaction do
      Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: OPS)

      assert_equal 120, Dials.checkout_fee_bps(market: "BD")
    end

    assert_equal 120, Dials.checkout_fee_bps(market: "BD")
  end

  private

  # Writes the row without going through Dials, which is what a write from a
  # second web process looks like from in here: the row lands, and nothing
  # tells this process's cache about it.
  def write_from_another_process(value)
    Dials::Record.create!(key: "checkout_fee_bps", scope: %({"market":"BD"}), value: value.to_json,
                          actor_label: "another process")
  end
end

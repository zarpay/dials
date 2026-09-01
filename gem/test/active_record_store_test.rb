# frozen_string_literal: true

require "test_helper"
require "dials/active_record"

class ActiveRecordStoreTest < Minitest::Test
  include DialsTestSupport

  def self.establish_schema!
    return if @schema_ready

    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    ActiveRecord::Schema.verbose = false
    # Mirrors lib/generators/dials/install/templates/migration.rb.tt.
    ActiveRecord::Schema.define do
      create_table :dials do |t|
        t.string :key, null: false, limit: 100
        t.string :scope, null: false, limit: 255
        t.text :value, null: false
        t.bigint :version, null: false
        t.timestamps
      end
      add_index :dials, %i[key scope], unique: true

      create_table :dial_changes do |t|
        t.string :key, null: false
        t.string :scope
        t.string :action, null: false
        t.text :old_value
        t.text :new_value
        t.string :actor_type
        t.string :actor_id
        t.string :actor_label
        t.datetime :created_at, null: false
      end
      add_index :dial_changes, :key
    end
    @schema_ready = true
  end

  def setup
    super
    self.class.establish_schema!
    Dials::ActiveRecord::Change.delete_all
    Dials::ActiveRecord::Override.delete_all
    Dials.configure { |c| c.store = :active_record }
    define_standard_dials
  end

  def overrides = Dials::ActiveRecord::Override

  def test_full_resolution_round_trip
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")

    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)

    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "NG")

    Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE")

    Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_no_rows_until_first_override
    Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 0, overrides.count
  end

  def test_a_global_is_the_override_at_the_empty_scope
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    row = overrides.sole
    assert_equal Dials::Scope::GLOBAL, row.scope
    assert_equal "150", row.value
  end

  def test_global_and_scoped_overrides_are_independent_rows
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 2, overrides.where(key: "merchant_fee_bps").count

    # Clearing the global deletes exactly its row; the scoped override survives
    # with nothing anchoring it — no parent, no NULL-value bookkeeping.
    Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal [%w[merchant_fee_bps KE]],
                 overrides.pluck(:key, :scope).map { |k, s| [k, JSON.parse(s)["market"]] }
    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "NG"), "global is back to the code default"
  end

  def test_removing_the_last_override_removes_all_rows
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 0, overrides.count
  end

  def test_clearing_global_without_scoped_overrides_removes_the_row
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal 0, overrides.count
  end

  def test_false_survives_the_database_round_trip
    Dials.set(:signups_enabled, false, actor: ACTOR)
    Dials.reload!
    assert_equal false, Dials.get(:signups_enabled)
    assert_equal "false", overrides.find_by!(key: "signups_enabled").value,
                 "false is stored as JSON text — the value column is NOT NULL by schema"
  end

  def test_scope_is_stored_canonically
    Dials.set(:free_delivery_threshold, 25, scope: { platform: :ios, "market" => "KE" }, actor: ACTOR)
    assert_equal '{"market":"KE","platform":"ios"}', overrides.sole.scope
  end

  def test_changes_round_trip_with_attribution
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 200, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, actor: ACTOR)

    changes = Dials.changes(key: :merchant_fee_bps)
    assert_equal %w[clear set set], changes.map(&:action)
    assert_equal 200, changes.first.old_value
    assert_equal 150, changes[1].old_value
    assert_nil changes[2].old_value
    assert_equal ACTOR, changes.first.actor_label
    assert changes.first.global?, "history keeps NULL scope for global changes"
  end

  def test_version_moves_on_every_write_and_powers_the_probe
    store = Dials.store
    v0 = store.version
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    v1 = store.version
    refute_equal v0, v1

    # Another process's write becomes visible once the probe runs.
    Dials.configure { |c| c.cache_ttl = 0 }
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE")
    store.set_override(:merchant_fee_bps, Dials::Scope::GLOBAL, 175,
                       { actor_type: nil, actor_id: nil, actor_label: "other-process" })
    assert_equal 175, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_json_type_round_trips_with_string_keys
    Dials.define { dial :fee_table, default: { "base" => 1 }, type: :json }
    Dials.set(:fee_table, { "base" => 2, "tiers" => [1, 2, 3] }, actor: ACTOR)
    Dials.reload!
    assert_equal({ "base" => 2, "tiers" => [1, 2, 3] }, Dials.get(:fee_table))
  end

  # The gap-commit scenario: transaction A claims change id 5 but commits
  # AFTER transaction B commits id 10. A process that cached version at
  # max-id 10 would never notice A's late commit if max id were the whole
  # version — the row count is what catches it.
  def test_version_catches_a_late_commit_with_a_lower_change_id
    Dials.configure { |c| c.cache_ttl = 0 }
    changes = Dials::ActiveRecord::Change

    changes.insert_all!([{ id: 10, key: "merchant_fee_bps", action: "set",
                           new_value: "150", created_at: Time.now.utc }])
    overrides.create!(key: "merchant_fee_bps", scope: Dials::Scope::GLOBAL, value: "150", version: 10)
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE") # cache warm at version [1, 10]

    # The "late commit": a lower change id appears without max(id) moving.
    changes.insert_all!([{ id: 5, key: "merchant_fee_bps", action: "set",
                           new_value: "175", created_at: Time.now.utc }])
    overrides.find_by!(key: "merchant_fee_bps").update!(value: "175")

    assert_equal 175, Dials.get(:merchant_fee_bps, market: "KE"),
                 "count moved 1 → 2, so the probe must rebuild even though max(id) is still 10"
  end

  def test_corrupt_global_row_is_quarantined_not_fatal
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    overrides.create!(key: "support_email", scope: Dials::Scope::GLOBAL, value: "{definitely not json", version: 1)
    Dials.reload!

    _out, err = capture_io do
      assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE"), "healthy dials keep resolving"
      assert_equal "support@example.com", Dials.get(:support_email), "the corrupt override is skipped, default serves"
    end
    assert_match(/skipping corrupt row/, err)
  end

  def test_malformed_scope_is_quarantined_not_fatal
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    overrides.insert_all!([{ key: "merchant_fee_bps", scope: "not-json", value: "77", version: 1,
                             created_at: Time.now.utc, updated_at: Time.now.utc }])
    Dials.reload!

    _out, err = capture_io do
      assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    end
    assert_match(/not valid JSON/, err)
  end

  def test_uncommitted_writes_never_poison_the_shared_cache
    Dials.configure { |c| c.cache_ttl = 3600 }
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE") # warm

    Dials::ActiveRecord::Override.transaction do
      Dials.set(:merchant_fee_bps, 500, actor: ACTOR)
      assert_equal 500, Dials.get(:merchant_fee_bps, market: "KE"),
                   "the writing thread reads its own uncommitted write"
      raise ActiveRecord::Rollback
    end

    assert_equal 100, Dials.get(:merchant_fee_bps, market: "KE"),
                 "after rollback the cache serves the committed state, not the poisoned value"
    assert_nil Thread.current[Dials::TXN_WRITE_KEY], "the transaction marker clears once the transaction closes"
  end

  def test_committed_transactional_write_is_visible_after_commit
    Dials.configure { |c| c.cache_ttl = 3600 }
    Dials::ActiveRecord::Override.transaction do
      Dials.set(:merchant_fee_bps, 500, actor: ACTOR)
    end
    assert_equal 500, Dials.get(:merchant_fee_bps, market: "KE")
  end

  # The writer might never read again. If another thread republished the
  # pre-transaction state mid-transaction (legitimate — the write wasn't
  # committed yet), only a bust ON COMMIT keeps that stale snapshot from
  # surviving a full TTL (or forever, with ttl = nil).
  def test_commit_busts_the_cache_even_if_the_writer_never_reads_again
    skip "requires ActiveRecord.after_all_transactions_commit (AR >= 7.2)" unless
      ActiveRecord.respond_to?(:after_all_transactions_commit)

    Dials.configure { |c| c.cache_ttl = nil } # no probe: only busts converge

    Dials::ActiveRecord::Override.transaction do
      Dials.set(:merchant_fee_bps, 500, actor: ACTOR)
      # Simulate another thread publishing a snapshot mid-transaction.
      Dials.cache.snapshot
      refute_nil Dials.cache.instance_variable_get(:@snapshot)
    end

    assert_nil Dials.cache.instance_variable_get(:@snapshot),
               "the commit hook must bust whatever was published mid-transaction"
  end

  def test_corrupt_change_row_is_quarantined_from_history
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials::ActiveRecord::Change.insert_all!([
                                              { key: "merchant_fee_bps", action: "set", scope: nil,
                                                new_value: "{broken", created_at: Time.now.utc },
                                              # Valid JSON, invalid shape: a scope must be an object.
                                              { key: "merchant_fee_bps", action: "set", scope: "42",
                                                new_value: "1", created_at: Time.now.utc }
                                            ])

    changes = nil
    _out, err = capture_io { changes = Dials.changes(key: :merchant_fee_bps) }
    assert_equal 1, changes.length, "the healthy change survives; both corrupt rows are skipped"
    assert_equal 150, changes.first.new_value
    assert_match(/skipping corrupt row/, err)
  end

  def test_change_rows_are_append_only_through_active_record
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    row = Dials::ActiveRecord::Change.sole
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.update!(action: "clear") }
    assert_raises(ActiveRecord::ReadOnlyRecord) { row.destroy! }
  end

  def test_json_symbol_keys_rejected_at_write_time
    Dials.define { dial :fee_table, default: { "base" => 1 }, type: :json }
    error = assert_raises(Dials::InvalidValue) { Dials.set(:fee_table, { base: 2 }, actor: ACTOR) }
    assert_match(/round-trip/, error.message)
  end

  def test_writes_bypassing_the_gem_need_a_manual_reload
    # Direct model writes skip validation, attribution, AND the version
    # counter (it is the change log's max id), so the staleness probe cannot
    # see them — each process needs a manual Dials.reload!. This test pins
    # that documented limitation.
    overrides.create!(key: "support_email", scope: Dials::Scope::GLOBAL,
                      value: JSON.generate("ops@example.com"), version: 1)
    Dials.reload!
    assert_equal "ops@example.com", Dials.get(:support_email)
  end

  # -- compare-and-swap (expected_version:) -----------------------------------

  def test_cas_write_against_an_absent_override_and_token_chaining
    token = Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: Dials::ABSENT_VERSION)
    assert_equal 200, Dials.use_merchant_fee_bps(market: "KE")

    # The returned token is the row's new stamp — usable for the next write.
    token = Dials.adjust_merchant_fee_bps(300, actor: ACTOR, expected_version: token)
    assert_equal 300, Dials.use_merchant_fee_bps(market: "KE")

    # A CAS clear returns ABSENT (the row is gone).
    token = Dials.clear_merchant_fee_bps(actor: ACTOR, expected_version: token)
    assert_equal Dials::ABSENT_VERSION, token
  end

  def test_row_versions_are_stamped_from_change_ids_so_recreation_never_reuses_one
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)
    first_version = overrides.sole.version
    Dials.clear_merchant_fee_bps(actor: ACTOR)
    Dials.adjust_merchant_fee_bps(200, actor: ACTOR)

    assert_operator overrides.sole.version, :>, first_version,
                    "a deleted-and-recreated row must never revisit an old version (no ABA)"
  end

  def test_stale_write_rolls_back_the_whole_transaction
    state = Dials.overview.dials.find { |d| d.key == :merchant_fee_bps }
    Dials.adjust_merchant_fee_bps(150, actor: ACTOR, market: "BD") # the override the page saw as absent appears

    changes_before = Dials::ActiveRecord::Change.count
    assert_raises(Dials::StaleWrite) do
      Dials.adjust_merchant_fee_bps(999, actor: ACTOR, market: "BD",
                                    expected_version: state.scoped_override_versions[{ market: "BD" }] || Dials::ABSENT_VERSION)
    end

    assert_equal changes_before, Dials::ActiveRecord::Change.count
    assert_equal 150, Dials.use_merchant_fee_bps(market: "BD"), "the stale write left the value untouched"
  end

  def test_unrelated_writes_do_not_conflict
    # Per-override granularity: another dial (or another scope) changing
    # cannot stale a write to this one.
    state = Dials.overview.dials.find { |d| d.key == :merchant_fee_bps }
    Dials.adjust_signups_enabled(false, actor: ACTOR)
    Dials.adjust_merchant_fee_bps(90, actor: ACTOR, market: "NG")

    Dials.adjust_merchant_fee_bps(200, actor: ACTOR, expected_version: state.global_version)
    assert_equal 200, Dials.use_merchant_fee_bps(market: "KE")
  end

  def test_stale_write_is_not_a_retryable_error
    # The retry loop re-running a CAS write would recompute against the new
    # version and succeed, silently defeating the mechanism. Pin the class
    # relationship the loop depends on.
    Dials::Stores::ActiveRecordStore::RETRYABLE.each do |retryable|
      refute_operator Dials::StaleWrite, :<=, retryable
    end
  end
end

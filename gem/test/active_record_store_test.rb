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
        t.string :key, null: false
        t.text :value
        t.timestamps
      end
      add_index :dials, :key, unique: true

      create_table :dial_variations do |t|
        t.references :dial, null: false, foreign_key: true
        t.string :scope, null: false
        t.text :value, null: false
        t.timestamps
      end
      add_index :dial_variations, %i[dial_id scope], unique: true

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
    Dials::ActiveRecord::Variation.delete_all
    Dials::ActiveRecord::Setting.delete_all
    Dials.configure { |c| c.store = :active_record }
    define_standard_dials
  end

  def settings = Dials::ActiveRecord::Setting
  def variations = Dials::ActiveRecord::Variation

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
    assert_equal 0, settings.count
  end

  def test_clearing_global_keeps_parent_row_while_variations_exist
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)

    Dials.clear(:merchant_fee_bps, actor: ACTOR)

    row = settings.find_by!(key: "merchant_fee_bps")
    assert_nil row.value, "parent row survives as a variation anchor with NULL value"
    assert_equal 90, Dials.get(:merchant_fee_bps, market: "KE")
    assert_equal 100, Dials.get(:merchant_fee_bps, market: "NG"), "global is back to the code default"
  end

  def test_removing_the_last_override_removes_all_rows
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: ACTOR)
    assert_equal 0, settings.count
    assert_equal 0, variations.count
  end

  def test_clearing_global_without_variations_removes_the_row
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    Dials.clear(:merchant_fee_bps, actor: ACTOR)
    assert_equal 0, settings.count
  end

  def test_false_survives_the_database_round_trip
    Dials.set(:signups_enabled, false, actor: ACTOR)
    Dials.reload!
    assert_equal false, Dials.get(:signups_enabled)
    refute_nil settings.find_by!(key: "signups_enabled").value, "false is stored as JSON, not SQL NULL"
  end

  def test_scope_is_stored_canonically
    Dials.set(:free_delivery_threshold, 25, scope: { platform: :ios, "market" => "KE" }, actor: ACTOR)
    assert_equal '{"market":"KE","platform":"ios"}', variations.sole.scope
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
    assert changes.first.global?
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
    store.set_global(:merchant_fee_bps, 175, { actor_type: nil, actor_id: nil, actor_label: "other-process" })
    assert_equal 175, Dials.get(:merchant_fee_bps, market: "KE")
  end

  def test_json_type_round_trips_with_string_keys
    Dials.define { dial :fee_table, { "base" => 1 }, type: :json }
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
    settings.create!(key: "merchant_fee_bps", value: "150")
    assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE") # cache warm at version [1, 10]

    # The "late commit": a lower change id appears without max(id) moving.
    changes.insert_all!([{ id: 5, key: "merchant_fee_bps", action: "set",
                           new_value: "175", created_at: Time.now.utc }])
    settings.find_by!(key: "merchant_fee_bps").update!(value: "175")

    assert_equal 175, Dials.get(:merchant_fee_bps, market: "KE"),
                 "count moved 1 → 2, so the probe must rebuild even though max(id) is still 10"
  end

  def test_corrupt_global_row_is_quarantined_not_fatal
    Dials.set(:merchant_fee_bps, 150, actor: ACTOR)
    settings.create!(key: "support_email", value: "{definitely not json")
    Dials.reload!

    _out, err = capture_io do
      assert_equal 150, Dials.get(:merchant_fee_bps, market: "KE"), "healthy dials keep resolving"
      assert_equal "support@example.com", Dials.get(:support_email), "the corrupt override is skipped, default serves"
    end
    assert_match(/skipping corrupt row/, err)
  end

  def test_malformed_variation_scope_is_quarantined_not_fatal
    Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: ACTOR)
    parent = settings.find_by!(key: "merchant_fee_bps")
    variations.insert_all!([{ dial_id: parent.id, scope: "not-json", value: "77",
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

    Dials::ActiveRecord::Setting.transaction do
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
    Dials::ActiveRecord::Setting.transaction do
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

    Dials::ActiveRecord::Setting.transaction do
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
    Dials.define { dial :fee_table, { "base" => 1 }, type: :json }
    error = assert_raises(Dials::InvalidValue) { Dials.set(:fee_table, { base: 2 }, actor: ACTOR) }
    assert_match(/round-trip/, error.message)
  end

  def test_writes_bypassing_the_gem_need_a_manual_reload
    # Direct model writes skip validation, attribution, AND the version
    # counter (it is the change log's max id), so the staleness probe cannot
    # see them — each process needs a manual Dials.reload!. This test pins
    # that documented limitation.
    settings.create!(key: "support_email", value: JSON.generate("ops@example.com"))
    Dials.reload!
    assert_equal "ops@example.com", Dials.get(:support_email)
  end
end

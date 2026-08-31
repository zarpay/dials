# frozen_string_literal: true

require "test_helper"

class CacheTest < Minitest::Test
  include DialsTestSupport

  ACTOR_ATTRS = { actor_type: nil, actor_id: nil, actor_label: "cache-test" }.freeze

  def setup
    super
    Dials.define { dial :fee, 100, type: :integer }
  end

  # Simulates another process writing to the shared store: mutate the store
  # directly, bypassing Dials.set (which would bust the local cache).
  def foreign_write(value)
    Dials.store.set_global(:fee, value, ACTOR_ATTRS)
  end

  def test_ttl_nil_never_probes
    Dials.configure { |c| c.cache_ttl = nil }
    assert_equal 100, Dials.get(:fee)
    foreign_write(200)
    assert_equal 100, Dials.get(:fee)
    Dials.reload!
    assert_equal 200, Dials.get(:fee)
  end

  def test_ttl_zero_probes_every_read
    Dials.configure { |c| c.cache_ttl = 0 }
    assert_equal 100, Dials.get(:fee)
    foreign_write(200)
    assert_equal 200, Dials.get(:fee)
  end

  def test_probe_rebuilds_only_when_version_moved
    Dials.configure { |c| c.cache_ttl = 0 }
    first = Dials.cache.snapshot
    assert_same first, Dials.cache.snapshot, "same version → same snapshot object, no rebuild"
    foreign_write(200)
    refute_same first, Dials.cache.snapshot
  end

  def test_positive_ttl_throttles_probes
    Dials.configure { |c| c.cache_ttl = 3600 }
    assert_equal 100, Dials.get(:fee)
    foreign_write(200)
    assert_equal 100, Dials.get(:fee), "within ttl the foreign write is not yet visible"
  end

  def test_local_writes_always_visible_immediately
    Dials.configure { |c| c.cache_ttl = 3600 }
    assert_equal 100, Dials.get(:fee)
    Dials.set(:fee, 300, actor: ACTOR)
    assert_equal 300, Dials.get(:fee)
  end

  def test_swapping_the_store_resets_the_cache
    Dials.set(:fee, 300, actor: ACTOR)
    assert_equal 300, Dials.get(:fee)
    Dials.configure { |c| c.store = :memory }
    assert_equal 100, Dials.get(:fee), "a fresh store has no overrides"
  end
end

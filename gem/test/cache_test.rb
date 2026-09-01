# frozen_string_literal: true

require "test_helper"

class CacheTest < Minitest::Test
  include DialsTestSupport

  ACTOR_ATTRS = { actor_type: nil, actor_id: nil, actor_label: "cache-test" }.freeze

  def setup
    super
    Dials.define { dial :fee, default: 100, type: :integer }
  end

  # Simulates another process writing to the shared store: mutate the store
  # directly, bypassing Dials.set (which would bust the local cache).
  def foreign_write(value)
    Dials.store.set_override(:fee, Dials::Scope::GLOBAL, value, ACTOR_ATTRS)
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

  # Wraps a real store; individual operations can be made to fail on demand.
  class FlakyStore
    attr_accessor :fail_version, :fail_state

    def initialize(inner)
      @inner = inner
      @fail_version = false
      @fail_state = false
    end

    def state = @fail_state ? raise("state boom") : @inner.state
    def version = @fail_version ? raise("version boom") : @inner.version

    def method_missing(name, *, &) = @inner.send(name, *, &)
    def respond_to_missing?(name, include_private = false) = @inner.respond_to?(name, include_private)
  end

  def flaky_setup
    flaky = FlakyStore.new(Dials::Stores::Memory.new)
    Dials.configure do |c|
      c.store = flaky
      c.cache_ttl = 0
    end
    flaky
  end

  def test_probe_failure_serves_the_cached_snapshot_and_warns
    flaky = flaky_setup
    assert_equal 100, Dials.get(:fee) # warm
    flaky.fail_version = true

    value = nil
    _out, err = capture_io { value = Dials.get(:fee) }
    assert_equal 100, value
    assert_match(/staleness probe failed/, err)
  end

  def test_rebuild_failure_serves_the_cached_snapshot_and_warns
    flaky = flaky_setup
    assert_equal 100, Dials.get(:fee) # warm
    foreign_write(200)                # version moves, so the probe wants a rebuild
    flaky.fail_state = true

    value = nil
    _out, err = capture_io { value = Dials.get(:fee) }
    assert_equal 100, value, "last-known-good beats an exception"
    assert_match(/rebuild failed/, err)

    flaky.fail_state = false
    assert_equal 200, Dials.get(:fee), "recovery converges on the next healthy read"
  end

  def test_cold_start_failure_raises
    flaky = flaky_setup
    flaky.fail_state = true
    error = assert_raises(RuntimeError) { Dials.get(:fee) }
    assert_equal "state boom", error.message
  end

  # A store wrapper that fires a callback at the start of each state read —
  # used to interleave a bust! into an in-flight rebuild.
  class TrapStore
    attr_accessor :on_state

    def initialize(inner)
      @inner = inner
      @on_state = nil
    end

    # Reads the state FIRST, then fires the callback, then returns the
    # already-read (pre-callback) state — modeling a rebuild that loaded
    # from the store just before a concurrent write landed.
    def state
      result = @inner.state
      callback = @on_state
      @on_state = nil
      callback&.call
      result
    end

    def method_missing(name, *, &) = @inner.send(name, *, &)
    def respond_to_missing?(name, include_private = false) = @inner.respond_to?(name, include_private)
  end

  def test_bust_during_an_inflight_rebuild_wins
    trap = TrapStore.new(Dials::Stores::Memory.new)
    Dials.configure do |c|
      c.store = trap
      c.cache_ttl = 3600
    end

    # While the rebuild is reading store state, a write lands and busts the
    # cache. The rebuild's snapshot predates that write; publishing it would
    # hide the write until the next probe (forever, with ttl = nil).
    trap.on_state = lambda do
      trap.set_override(:fee, Dials::Scope::GLOBAL, 999, ACTOR_ATTRS)
      Dials.cache.bust!
    end

    assert_equal 100, Dials.get(:fee), "the interleaved snapshot predates the write; the requesting reader may still use it"
    assert_equal 999, Dials.get(:fee), "but it must not have been published — the next read rebuilds fresh"
  end

  def test_swapping_the_store_resets_the_cache
    Dials.set(:fee, 300, actor: ACTOR)
    assert_equal 300, Dials.get(:fee)
    Dials.configure { |c| c.store = :memory }
    assert_equal 100, Dials.get(:fee), "a fresh store has no overrides"
  end
end

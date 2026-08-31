# frozen_string_literal: true

module Dials
  # Per-process, in-memory snapshot cache.
  #
  # Reads never query the store per-dial: they read from the current
  # Snapshot. The snapshot is (re)built from the store on first use, and
  # thereafter freshness is maintained two ways:
  #
  #   1. Local writes bust the cache immediately — the process that made a
  #      change reads its own write on the next get.
  #   2. Other processes converge via a throttled staleness probe: at most
  #      once per `ttl` seconds, a read asks the store for its version (a
  #      single cheap query — the max change id) and rebuilds only when it
  #      moved.
  #
  # ttl = 0 probes on every read (strong consistency, one extra query per
  # read); ttl = nil never probes (bust!/reload! only). Default is 5 seconds.
  class Cache
    def initialize(store:, ttl: 5.0)
      @store = store
      @ttl = ttl
      @mutex = Mutex.new
      @snapshot = nil
      @probed_at = nil
    end

    attr_accessor :ttl

    def snapshot
      current = @snapshot
      return rebuild if current.nil?
      return current unless probe_due?
      return current if @store.version == current.version

      rebuild
    rescue StandardError
      @mutex.synchronize { @snapshot = nil }
      raise
    end

    def bust!
      @mutex.synchronize do
        @snapshot = nil
        @probed_at = nil
      end
    end

    private

    def probe_due?
      return false if @ttl.nil?
      return true if @ttl.zero?

      due = @probed_at.nil? || (monotonic_now - @probed_at) >= @ttl
      @probed_at = monotonic_now if due
      due
    end

    def rebuild
      @mutex.synchronize do
        state = @store.state
        @snapshot = Snapshot.new(**state)
        @probed_at = monotonic_now
        @snapshot
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

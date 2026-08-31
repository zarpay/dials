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
  #      single cheap query) and rebuilds only when it moved.
  #
  # ttl = 0 probes on every read (strong consistency, one extra query per
  # read); ttl = nil never probes (bust!/reload! only). Default is 5 seconds.
  #
  # Concurrency rules (each one is a production lesson, not a style choice):
  #
  #   - The store is NEVER queried while holding a lock. Holding a mutex
  #     across a database call can deadlock a multi-threaded server: the
  #     builder waits for a pooled connection while every connection is held
  #     by threads blocked on the mutex.
  #   - A stale refresh is single-flight (try_lock); threads that lose the
  #     race serve the still-valid current snapshot instead of stampeding
  #     the database. The probe timestamp is claimed BEFORE the version
  #     query, so a burst of readers crossing the TTL boundary doesn't fan
  #     out into a probe stampede either.
  #   - A bust! that lands while a rebuild is in flight WINS: the rebuild
  #     read state before the bust's write, so publishing it would hide that
  #     write for a full TTL. The generation counter detects this and drops
  #     the stale publish (the requesting reader still gets the built
  #     snapshot; the next reader rebuilds fresh).
  #   - Once a snapshot exists, probe and rebuild failures serve
  #     last-known-good (with a warning) rather than raising — a database
  #     blip must not take down every dial read. With no snapshot at all,
  #     failures raise: there is nothing honest to serve.
  class Cache
    def initialize(store:, ttl: 5.0)
      @store = store
      @ttl = ttl
      @build_mutex = Mutex.new
      @state_mutex = Mutex.new # guards @generation/@snapshot writes; never held across store calls
      @snapshot = nil
      @probed_at = nil
      @generation = 0
    end

    attr_accessor :ttl

    def snapshot
      current = @snapshot
      return build_and_publish if current.nil?
      return current unless probe_due?

      # Claim the probe slot up front: concurrent readers crossing the TTL
      # boundary see a fresh timestamp and skip their own probes.
      @probed_at = monotonic_now

      begin
        return current if @store.version == current.version
      rescue StandardError => e
        warn "[dials] staleness probe failed; serving the cached snapshot (#{e.class}: #{e.message})"
        return current
      end

      refresh(current)
    end

    # A fresh, UNPUBLISHED snapshot straight from the store. Used for reads
    # that must not pollute (or be served from) the shared cache — e.g. a
    # thread that wrote a dial inside a still-open database transaction and
    # must see its own uncommitted state without leaking it to other threads.
    def uncached_snapshot
      Snapshot.new(**@store.state)
    end

    def bust!
      @state_mutex.synchronize do
        @generation += 1
        @snapshot = nil
        @probed_at = nil
      end
    end

    private

    def probe_due?
      return false if @ttl.nil?
      return true if @ttl.zero?

      last = @probed_at
      last.nil? || (monotonic_now - last) >= @ttl
    end

    # Cold start: build without any lock. Concurrent cold readers each build
    # once (a bounded, once-per-boot herd against two small tables); the last
    # assignment wins with a valid snapshot either way. Failures raise —
    # there is no last-known-good yet.
    def build_and_publish
      generation = @state_mutex.synchronize { @generation }
      built = Snapshot.new(**@store.state)

      # Publish only if no bust! landed while we were reading the store —
      # otherwise this snapshot predates a write and must not become the
      # shared state. Check and assignment share the state mutex so a bust!
      # cannot slip between them. The caller still gets the built snapshot.
      @state_mutex.synchronize do
        if generation == @generation
          @probed_at = monotonic_now
          @snapshot = built
        end
      end

      built
    end

    def refresh(current)
      return current unless @build_mutex.try_lock

      begin
        build_and_publish
      rescue StandardError => e
        warn "[dials] snapshot rebuild failed; serving the cached snapshot (#{e.class}: #{e.message})"
        current
      ensure
        @build_mutex.unlock
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

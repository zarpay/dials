# frozen_string_literal: true

require "json"

require_relative "dials/version"
require_relative "dials/errors"
require_relative "dials/generated"
require_relative "dials/freeze"
require_relative "dials/dimension"
require_relative "dials/definition"
require_relative "dials/registry"
require_relative "dials/scope"
require_relative "dials/snapshot"
require_relative "dials/resolver"
require_relative "dials/cache"
require_relative "dials/change_record"
require_relative "dials/actor"
require_relative "dials/stores/memory"
require_relative "dials/config"
require_relative "dials/testing"

# Dials: operator-adjustable values with per-variant overrides.
#
# A dial is a value that starts life as a code default, can be overridden
# globally at runtime, and can be overridden again per variant scope
# (per market, per platform, ...). Resolution is always:
#
#   variation → global override → code default
#
# Declarations live in code (Dials.define); values live in a store; reads
# come from a per-process cache. Every write is attributed and logged.
#
# Declaring a dial generates its methods (see Generated):
#
#   Dials.use_base_fee(market: "KE")                  # read
#   Dials.adjust_base_fee(25, actor: ops, market: "KE") # write
#   Dials.clear_base_fee(actor: ops, market: "KE")      # remove an override
#
# The key-taking primitives (get, set, clear) stay public underneath — they
# are the dynamic-access layer for code that receives the key at runtime
# (an admin surface iterating the registry, a console one-liner).
module Dials
  # Thread-local marker: this thread performed a dial write inside a
  # database transaction that is still open. While set, the thread's reads
  # come from fresh, UNPUBLISHED snapshots — it sees its own uncommitted
  # write, but the uncommitted value never lands in the shared cache (where
  # other threads would read it, and where it would survive a rollback).
  TXN_WRITE_KEY = :dials_wrote_in_open_transaction

  CACHE_LOCK = Mutex.new

  class << self
    # -- declaration ---------------------------------------------------------

    attr_reader :registry, :config

    # Declare dials:
    #
    #   Dials.define do
    #     dial :merchant_fee_bps, default: 100, type: :integer, bounds: 1..10_000,
    #          unit: "bps", variants: { market: { options: %w[KE NG BD] } }
    #     dial :signups_enabled, default: true, type: :boolean
    #   end
    #
    # Each declaration generates the dial's methods: use_merchant_fee_bps,
    # adjust_merchant_fee_bps, clear_merchant_fee_bps (see Generated).
    def define(&)
      registry.instance_eval(&)
    end

    # -- configuration -------------------------------------------------------

    def configure
      yield config
    end

    def store
      config.store
    end

    def cache
      @cache || CACHE_LOCK.synchronize { @cache ||= Cache.new(store: store, ttl: config.cache_ttl) }
    end

    # Discard the cache object entirely (used when the store is swapped).
    def reset_cache!
      CACHE_LOCK.synchronize { @cache = nil }
    end

    # Force the next read to rebuild from the store — e.g. after writing
    # through a console in another process, or in a test. Also clears this
    # thread's in-transaction-write marker (test suites that wrap examples
    # in transactions call this between examples).
    def reload!
      Thread.current[TXN_WRITE_KEY] = nil
      cache.bust!
    end

    # -- reads ---------------------------------------------------------------

    # Resolve a dial by key — the primitive under the generated use_<key>
    # methods, for callers that receive the key at runtime. Scope is passed
    # as keyword arguments and must name every dimension the dial declares —
    # no more, no less:
    #
    #   Dials.get(:signups_enabled)                     # global-only dial
    #   Dials.get(:merchant_fee_bps, market: "KE")      # varied dial
    #
    # Raises UnknownDial / InvalidScope on misuse; never raises for a merely
    # missing override (that is what defaults are for).
    def get(key, **scope)
      definition = registry.fetch(key)
      normalized = Scope.validate!(definition, scope, exact: true)

      # After scope validation, so a test override can never mask a read that
      # would raise in production.
      pinned = Testing.override_for(definition.key)
      return pinned.first if pinned

      Resolver.resolve(definition, normalized, current_snapshot)
    end

    # The full change log, newest first. `key:` filters to one dial.
    def changes(key: nil, limit: 50)
      key = registry.fetch(key).key if key
      store.changes(key: key, limit: limit)
    end

    # -- writes --------------------------------------------------------------

    # Store an override by key — the primitive under the generated
    # adjust_<key> methods. With no scope, overrides the global; with a
    # scope, creates or updates the variation for exactly that scope. The
    # value is validated against the dial's type and bounds; `actor:` is
    # required and lands in the change log.
    def set(key, value, actor:, scope: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor)
      definition.validate_value!(value)

      if scope.nil? || scope.empty?
        store.set_global(definition.key, value, actor_attrs)
      else
        raise InvalidScope, "dial #{definition.key} declares no variants" unless definition.variants?

        normalized = Scope.validate!(definition, scope, exact: true)
        store.set_variation(definition.key, Scope.canonical(normalized), value, actor_attrs)
      end

      after_write
      value
    end

    # Remove an override by key — the primitive under the generated
    # clear_<key> methods — returning resolution to the next layer down: a
    # cleared variation inherits the global; a cleared global inherits the
    # code default. Returns true if an override existed. Clearing what is not
    # there is a no-op (and logs nothing).
    def clear(key, actor:, scope: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor)

      removed =
        if scope.nil? || scope.empty?
          store.clear_global(definition.key, actor_attrs)
        else
          normalized = Scope.validate!(definition, scope, exact: true)
          store.clear_variation(definition.key, Scope.canonical(normalized), actor_attrs)
        end

      after_write
      removed
    end

    private

    def after_write
      cache.bust!
      return unless store_transaction_open?

      # The write is inside an application transaction and not committed
      # yet. Two things follow. This thread's reads must bypass the shared
      # cache until the transaction closes (see current_snapshot). And the
      # bust above happened PRE-commit — another thread can legitimately
      # republish the pre-transaction state before the commit lands — so the
      # cache must be busted again ON commit, or a writer that never reads
      # again would leave every process serving the old value until the TTL
      # probe notices (forever, with ttl = nil). On rollback the hook is
      # discarded: the shared cache never held the transaction's data.
      Thread.current[TXN_WRITE_KEY] = true
      store.after_commit { cache.bust! } if store.respond_to?(:after_commit)
    end

    def current_snapshot
      if Thread.current[TXN_WRITE_KEY]
        return cache.uncached_snapshot if store_transaction_open?

        # The transaction closed (committed or rolled back). Rejoin the
        # shared cache, busting first so the next snapshot reflects the
        # outcome rather than anything published mid-transaction.
        Thread.current[TXN_WRITE_KEY] = nil
        cache.bust!
      end

      cache.snapshot
    end

    def store_transaction_open?
      s = store
      s.respond_to?(:transaction_open?) && s.transaction_open?
    end
  end

  @registry = Registry.new
  @config = Config.new
end

begin
  require "rails/railtie"
  require_relative "dials/railtie"
rescue LoadError
  nil
rescue StandardError => e
  # A broken or incompatible Rails installation must not stop the core gem
  # from loading — Rails integration is opportunistic, never required.
  warn "[dials] skipping Rails integration (#{e.class}: #{e.message})"
end

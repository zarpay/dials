# frozen_string_literal: true

require "json"

require_relative "dials/version"
require_relative "dials/errors"
require_relative "dials/generated"
require_relative "dials/freeze"
require_relative "dials/schema"
require_relative "dials/dimension"
require_relative "dials/definition"
require_relative "dials/registry"
require_relative "dials/scope"
require_relative "dials/snapshot"
require_relative "dials/store_version"
require_relative "dials/overview"
require_relative "dials/resolver"
require_relative "dials/cache"
require_relative "dials/change_record"
require_relative "dials/actor"
require_relative "dials/stores/memory"
require_relative "dials/config"
require_relative "dials/testing"

# Dials: operator-adjustable values with per-scope overrides.
#
# A dial is a value that starts life as a code default, can be overridden
# globally at runtime, and can be overridden again per scope along its
# declared dimensions (per market, per platform, ...). Resolution is always:
#
#   scoped override → global override → code default
#
# Declarations live in code (Dials.define); values live in a store; reads
# come from a per-process cache. Every write is attributed and logged.
#
# Declaring a dial generates its methods (see Generated):
#
#   Dials.base_fee(market: "KE")                        # read
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

  # The stale-write token of an override that is not stored. Pass it as
  # `expected_version:` to assert "there was no override here when I looked"
  # — the write succeeds only if that is still true.
  ABSENT_VERSION = StoreVersion::ABSENT

  class << self
    # -- declaration ---------------------------------------------------------

    attr_reader :registry, :config

    # Declare dials:
    #
    #   Dials.define do
    #     dial :merchant_fee_bps, default: 100, type: :integer,
    #          minimum: 1, maximum: 10_000, unit: "bps",
    #          dimensions: { market: { enum: %w[KE NG BD] } }
    #     dial :signups_enabled, default: true, type: :boolean
    #   end
    #
    # Each declaration generates the dial's methods: merchant_fee_bps (the
    # reader), adjust_merchant_fee_bps, clear_merchant_fee_bps (see
    # Generated).
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

    # Resolve a dial by key — the primitive under the generated readers,
    # for callers that receive the key at runtime. Scope is passed
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

    # One dial's stored scoped overrides as { parsed scope => value }, e.g.
    # { { market: "BD" } => 24, { market: "NG" } => 48 } — "which markets
    # override this dial?". Scopes come back as parsed hashes, never
    # canonical scope strings. A dial with nothing scoped stored (or no
    # dimensions at all) returns {}; the global override is not included
    # (see overview). Reads from the same snapshot path as the generated
    # readers, including the in-transaction rule. The result is deep-frozen —
    # it shares structure with the process-wide snapshot.
    def scoped_overrides(key)
      definition = registry.fetch(key)
      parsed_scoped_overrides(current_snapshot, definition.key)
    end

    # Every registered dial's full state — definition (with its JSON Schema),
    # global override (explicitly present-or-absent), scoped overrides, and
    # the per-override stale-write tokens — read from ONE snapshot, so the
    # picture is coherent. Feed an override's token back as
    # `expected_version:` when writing it (Dials::ABSENT_VERSION for
    # overrides the page showed as not stored).
    def overview
      snapshot = current_snapshot
      dials = registry.map do |definition|
        stamps = snapshot.row_versions[definition.key] || {}
        DialState.new(
          definition: definition,
          global_override: snapshot.globals.key?(definition.key),
          global_value: snapshot.globals[definition.key],
          global_version: StoreVersion.token(stamps[Scope::GLOBAL] || 0),
          scoped_overrides: parsed_scoped_overrides(snapshot, definition.key),
          scoped_override_versions: parsed_versions(snapshot, definition.key)
        )
      end.freeze
      Overview.new(version: StoreVersion.token(snapshot.version), dials: dials)
    end

    # The full change log, newest first. `key:` filters to one dial.
    def changes(key: nil, limit: 50)
      key = registry.fetch(key).key if key
      store.changes(key: key, limit: limit)
    end

    # -- writes --------------------------------------------------------------

    # Store an override by key — the primitive under the generated
    # adjust_<key> methods. With no scope, overrides the global; with a
    # scope, creates or updates the override for exactly that scope. The
    # value is validated against the dial's type and schema; `actor:` is
    # required and lands in the change log.
    #
    # `expected_version:` makes the write compare-and-swap against THIS
    # override (the global when no scope keywords, the named scoped override
    # otherwise): pass the override's token from Dials.overview (or a
    # previous CAS write; Dials::ABSENT_VERSION when the page showed no
    # override) and the write is refused with StaleWrite — unapplied,
    # unlogged — if that override has changed since. A CAS write returns the
    # override's NEW token (chain it into the next write); an unconditional
    # write returns the value, as always.
    def set(key, value, actor:, scope: nil, expected_version: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor)
      definition.validate_value!(value)

      if scope.nil? || scope.empty?
        canonical = Scope::GLOBAL
      else
        raise InvalidScope, "dial #{definition.key} declares no dimensions" unless definition.dimensions?

        normalized = Scope.validate!(definition, scope, exact: true)
        canonical = Scope.canonical(normalized)
      end
      store.set_override(definition.key, canonical, value, actor_attrs, expected_version: expected_version)

      after_write
      expected_version ? StoreVersion.token(store.override_version(definition.key, canonical)) : value
    end

    # Remove an override by key — the primitive under the generated
    # clear_<key> methods — returning resolution to the next layer down: a
    # cleared scoped override inherits the global; a cleared global inherits the
    # code default. Returns true if an override existed. Clearing what is not
    # there is a no-op (and logs nothing).
    #
    # `expected_version:` works exactly as on set — the staleness check runs
    # even when the clear would be a no-op (a page that shows an override
    # which no longer exists IS stale), and a CAS clear returns the
    # override's new token (Dials::ABSENT_VERSION, since it is now gone)
    # instead of the boolean.
    def clear(key, actor:, scope: nil, expected_version: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor)

      if scope.nil? || scope.empty?
        canonical = Scope::GLOBAL
      else
        normalized = Scope.validate!(definition, scope, exact: true)
        canonical = Scope.canonical(normalized)
      end
      removed = store.clear_override(definition.key, canonical, actor_attrs,
                                     expected_version: expected_version)

      after_write
      expected_version ? StoreVersion.token(store.override_version(definition.key, canonical)) : removed
    end

    private

    # { canonical scope string => value } from the snapshot, re-keyed by
    # parsed scope hash. Values are already frozen snapshot references; the
    # freshly built hashes are frozen so no caller can mutate shared state.
    def parsed_scoped_overrides(snapshot, key)
      stored = snapshot.scoped_overrides[key] || {}
      stored.to_h { |canonical, value| [Freeze.deep(Scope.parse(canonical)), value] }.freeze
    end

    # { parsed scope hash => version token } for a dial's scoped overrides.
    def parsed_versions(snapshot, key)
      stamps = snapshot.row_versions[key] || {}
      stamps.except(Scope::GLOBAL)
            .to_h { |canonical, stamp| [Freeze.deep(Scope.parse(canonical)), StoreVersion.token(stamp)] }.freeze
    end

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

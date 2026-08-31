# frozen_string_literal: true

require "json"

require_relative "dials/version"
require_relative "dials/errors"
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
module Dials
  class << self
    # -- declaration ---------------------------------------------------------

    def registry
      @registry ||= Registry.new
    end

    # Declare dials:
    #
    #   Dials.define do
    #     dial :merchant_fee_bps, 100, type: :integer, bounds: 1..10_000,
    #          unit: "bps", variants: { market: { options: %w[KE NG BD] } }
    #     dial :signups_enabled, true, type: :boolean
    #   end
    def define(&)
      registry.instance_eval(&)
    end

    # -- configuration -------------------------------------------------------

    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    def store
      config.store
    end

    def cache
      @cache ||= Cache.new(store: store, ttl: config.cache_ttl)
    end

    # Discard the cache object entirely (used when the store is swapped).
    def reset_cache!
      @cache = nil
    end

    # Force the next read to rebuild from the store — e.g. after writing
    # through a console in another process, or in a test.
    def reload!
      cache.bust!
    end

    # -- reads ---------------------------------------------------------------

    # Resolve a dial. Scope is passed as keyword arguments and must name
    # every dimension the dial declares — no more, no less:
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

      Resolver.resolve(definition, normalized, cache.snapshot)
    end

    # The full change log, newest first. `key:` filters to one dial.
    def changes(key: nil, limit: 50)
      key = registry.fetch(key).key if key
      store.changes(key: key, limit: limit)
    end

    # -- writes --------------------------------------------------------------

    # Store an override. With no scope, overrides the global; with a scope,
    # creates or updates the variation for exactly that scope. The value is
    # validated against the dial's type and bounds; `actor:` is required and
    # lands in the change log.
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

      cache.bust!
      value
    end

    # Remove an override, returning resolution to the next layer down: a
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

      cache.bust!
      removed
    end
  end
end

begin
  require "rails/railtie"
  require_relative "dials/railtie"
rescue LoadError
  nil
end

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
require_relative "dials/storage"
require_relative "dials/config"
require_relative "dials/namespace"
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
#
# Every method here belongs to the DEFAULT namespace (see Namespace): the
# app's own dials, in the app's own table. A subsystem that owns its
# settings end to end declares a namespace of its own instead:
#
#   Shipping = Dials.namespace(:shipping) { |config| config.store = :active_record }
#
# and gets the same API on that object, against a table of its own.
module Dials
  # Guards the check-then-set in `namespace`, so two engine initializers
  # declaring at once cannot both win. Declarations only; a fetch reads the
  # table without it.
  NAMESPACE_LOCK = Mutex.new

  # The stale-write token of an override that is not stored. Pass it as
  # `expected_version:` to assert "there was no override here when I looked"
  # — the write succeeds only if that is still true.
  ABSENT_VERSION = StoreVersion::ABSENT

  class << self
    # -- namespaces ----------------------------------------------------------

    # The root namespace, the one every method on this module delegates to.
    attr_reader :default

    # Every namespace, root first, then registration order — what an admin
    # surface iterates to group dials by subsystem without naming one.
    def namespaces
      @namespaces.values
    end

    # Declare a namespace (with a block or a label), or fetch one by name:
    #
    #   Shipping = Dials.namespace(:shipping, label: "Shipping") do |config|
    #     config.store = :active_record        # table: "shipping_dials"
    #   end
    #
    #   Dials.namespace(:shipping)             # the same object, later
    #
    # Options the block leaves alone inherit the root's config. Declaring a
    # name twice raises DuplicateNamespace; fetching one that was never
    # declared raises UnknownNamespace.
    def namespace(name, label: nil, &block)
      key = name.to_sym
      return fetch_namespace(key, name) if label.nil? && block.nil?

      NAMESPACE_LOCK.synchronize { assert_undeclared!(key) }
      namespace = Namespace.new(key, label: label, parent: default)

      # The block runs application code (it can build a store, touch
      # ActiveRecord, even declare dials), so it runs outside the lock — and
      # before the namespace is published, so no other thread can reach one
      # that is still on the inherited store.
      namespace.configure(&block) if block
      NAMESPACE_LOCK.synchronize do
        assert_undeclared!(key)
        @namespaces[key] = namespace
      end
      namespace
    end

    # Test hook: discard every namespace but the root, and with them their
    # registries and generated methods. A suite that declares namespaces
    # needs a blank slate per example.
    def reset_namespaces!
      discarded = NAMESPACE_LOCK.synchronize do
        dropped = @namespaces.except(Namespace::ROOT_NAME).values
        @namespaces = { Namespace::ROOT_NAME => @default }
        dropped
      end
      @default.forget_children!
      discarded.each { |namespace| Thread.current[namespace.txn_write_key] = nil }
    end

    # Force every namespace's next read to rebuild from its store, and clear
    # every in-transaction-write marker — one call for a test suite that
    # wraps examples in transactions.
    def reload_all!
      namespaces.each(&:reload!)
    end

    # -- the default namespace -----------------------------------------------

    def registry
      default.registry
    end

    def config
      default.config
    end

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
      default.define(&)
    end

    def configure(&)
      default.configure(&)
    end

    def store
      default.store
    end

    def cache
      default.cache
    end

    def reset_cache!
      default.reset_cache!
    end

    def reload!
      default.reload!
    end

    def get(key, **scope)
      default.get(key, **scope)
    end

    def global(key)
      default.global(key)
    end

    def scoped_overrides(key)
      default.scoped_overrides(key)
    end

    def overview
      default.overview
    end

    def changes(key: nil, limit: 50)
      default.changes(key: key, limit: limit)
    end

    def set(key, value, actor:, scope: nil, expected_version: nil)
      default.set(key, value, actor: actor, scope: scope, expected_version: expected_version)
    end

    def clear(key, actor:, scope: nil, expected_version: nil)
      default.clear(key, actor: actor, scope: scope, expected_version: expected_version)
    end

    private

    def fetch_namespace(key, name)
      @namespaces.fetch(key) do
        raise UnknownNamespace,
              "no namespace named #{name.inspect} (declared: #{@namespaces.keys.join(', ')})"
      end
    end

    def assert_undeclared!(key)
      raise DuplicateNamespace, "namespace #{key.inspect} is already declared" if @namespaces.key?(key)
    end
  end

  # Populated before the root exists: building a namespace asks which
  # tables are already claimed.
  @namespaces = {}
  @default = Namespace.new(Namespace::ROOT_NAME)
  @namespaces[Namespace::ROOT_NAME] = @default

  # The root namespace's in-transaction marker (see Namespace#after_write);
  # every namespace has one of its own.
  TXN_WRITE_KEY = @default.txn_write_key

  # The generated readers of the root namespace answer on this module too,
  # so `Dials.merchant_fee_bps` keeps working: the methods are defined once,
  # in the namespace's module, and `self` decides whose dials they resolve.
  extend @default.generated_module
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

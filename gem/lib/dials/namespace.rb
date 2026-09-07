# frozen_string_literal: true

module Dials
  # A full dials instance: its own registry, config, store, table, cache,
  # change log, generated readers and test overrides. A subsystem that owns
  # a namespace owns its operator settings end to end — nothing it declares
  # or writes touches the host app's dials, and nothing the host writes
  # touches its own.
  #
  # The root namespace (name :default) is the one the `Dials` module itself
  # delegates to, so an app that never mentions namespaces uses exactly one.
  # Every other namespace is created with Dials.namespace:
  #
  #   Shipping = Dials.namespace(:shipping, label: "Shipping") do |config|
  #     config.store = :active_record          # table: "shipping_dials"
  #   end
  #
  #   Shipping.define { dial :max_parcel_kg, default: 20, type: :integer }
  #   Shipping.max_parcel_kg                   # => 20
  #
  # A dial resolves inside its namespace only: there is no cross-namespace
  # fallback, and the same key may be declared in two namespaces.
  class Namespace
    ROOT_NAME = :default

    # A name becomes a table name and (for an ActiveRecord store) a model
    # class name. Every segment starts with a letter, so camelizing the
    # segments is reversible and two names can never derive one model class:
    # "flat_rate" -> FlatRateEntry, and nothing else does.
    NAME_FORMAT = /\A[a-z][a-z0-9]*(_[a-z][a-z0-9]*)*\z/

    attr_reader :name, :registry, :config, :txn_write_key

    # The module holding this namespace's generated per-dial methods.
    attr_reader :generated_module

    def initialize(name, label: nil, parent: nil)
      @name = name.to_sym
      unless NAME_FORMAT.match?(@name.to_s)
        raise InvalidNamespace, "#{name.inspect}: a namespace name must be lowercase segments of " \
                                "letters and digits, each starting with a letter, joined by single " \
                                "underscores (it becomes a table name and a model class name)"
      end

      @parent = parent
      @children = []
      @generated_module = Module.new
      @cache_lock = Mutex.new
      @cache = nil
      # Per namespace, so a write in one namespace never changes how another
      # reads: the marker is keyed by name, not shared.
      @txn_write_key = :"dials_wrote_in_open_transaction_#{@name}"

      @registry = Registry.new(self)
      @storage = Storage.new(self, parent: parent&.storage)
      @config = Config.new(self, @storage, parent: parent&.config)
      @config.label = label if label
      extend @generated_module

      parent&.adopt(self)
    end

    def root?
      @name == ROOT_NAME
    end

    def label
      config.label
    end

    def default_label
      root? ? "Dials" : @name.to_s.tr("_", " ").capitalize
    end

    def inspect
      "#<Dials::Namespace #{@name} #{registry.keys.length} dials>"
    end

    # -- declaration ---------------------------------------------------------

    # Declare dials in this namespace:
    #
    #   ns.define do
    #     dial :merchant_fee_bps, default: 100, type: :integer,
    #          minimum: 1, maximum: 10_000, unit: "bps",
    #          dimensions: { market: { enum: %w[KE NG BD] } }
    #   end
    #
    # Each declaration generates the dial's methods on this namespace:
    # merchant_fee_bps (the reader), adjust_merchant_fee_bps,
    # clear_merchant_fee_bps (see Generated).
    def define(&)
      registry.instance_eval(&)
    end

    # Internal, called by the registry; see Generated.install!.
    def install_generated!(definition)
      Generated.install!(definition, into: @generated_module, owners: collision_owners)
    end

    def uninstall_generated!
      Generated.uninstall_all!(from: @generated_module)
    end

    # -- configuration -------------------------------------------------------

    def configure
      yield config
    end

    def store
      config.store
    end

    def cache
      @cache || @cache_lock.synchronize { @cache ||= Cache.new(store: store, ttl: config.cache_ttl) }
    end

    # Discard the cache object entirely (used when the store is swapped).
    def reset_cache!
      @cache_lock.synchronize { @cache = nil }
    end

    # Force the next read to rebuild from the store — e.g. after writing
    # through a console in another process, or in a test. Also clears this
    # thread's in-transaction-write marker (test suites that wrap examples
    # in transactions call this between examples).
    def reload!
      Thread.current[@txn_write_key] = nil
      cache.bust!
    end

    # Test hook: forget every option this namespace was configured with,
    # and the store built from them, so an example starts from the shipped
    # defaults.
    def reset_config!
      @storage = Storage.new(self, parent: @parent&.storage)
      @config = Config.new(self, @storage, parent: @parent&.config)
      reset_cache!
    end

    # Test hook for Dials.reset_namespaces!: a discarded namespace stops
    # inheriting config changes.
    def forget_children!
      @children.clear
    end

    # Internal: a cache_ttl change reaches the namespace's own cache, and
    # every namespace that inherits the value rather than declaring one.
    def apply_cache_ttl
      @cache&.ttl = config.cache_ttl
      @children.each(&:inherit_cache_ttl)
    end

    # Internal: same for a store swap. A namespace that inherits the kind
    # discards the store it built from the OLD kind — an app that configures
    # Dials after an engine declared its namespace must not leave that
    # engine on the default memory store.
    def apply_store
      reset_cache!
      @children.each(&:inherit_store)
    end

    # -- reads ---------------------------------------------------------------

    # Resolve a dial by key — the primitive under the generated readers,
    # for callers that receive the key at runtime. Scope is passed
    # as keyword arguments and must name every dimension the dial declares —
    # no more, no less:
    #
    #   ns.get(:signups_enabled)                     # global-only dial
    #   ns.get(:merchant_fee_bps, market: "KE")      # varied dial
    #
    # Raises UnknownDial / InvalidScope on misuse; never raises for a merely
    # missing override (that is what defaults are for).
    def get(key, **scope)
      definition = registry.fetch(key)
      normalized = Scope.validate!(definition, scope, exact: true)

      # After scope validation, so a test override can never mask a read that
      # would raise in production.
      pinned = Testing.override_for(self, definition.key)
      return pinned.first if pinned

      Resolver.resolve(definition, normalized, current_snapshot)
    end

    # Read a dial's Global layer by key: the stored global override when
    # present, else the code default — the tail every un-overridden scope
    # falls through to. This is the front door for the caller that has NO
    # scope to give — resolving a value for a subject whose dimension is
    # unknowable (a recipient with no resolvable market) — not a way around
    # exact-scope reads: a caller that knows its scope must still pass it
    # to get, which raises InvalidScope precisely so a lazy read cannot
    # skip a scoped override. For a dial with no dimensions this is
    # equivalent to get. Raises UnknownDial; honors Testing pins.
    def global(key)
      definition = registry.fetch(key)

      pinned = Testing.override_for(self, definition.key)
      return pinned.first if pinned

      # The empty scope matches no stored scoped override, so Resolver
      # takes exactly the global-override → code-default tail.
      Resolver.resolve(definition, {}, current_snapshot)
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

    # Every dial registered in this namespace, with its full state —
    # definition (with its JSON Schema), global override (explicitly
    # present-or-absent), scoped overrides, and the per-override stale-write
    # tokens — read from ONE snapshot, so the picture is coherent. Feed an
    # override's token back as `expected_version:` when writing it
    # (Dials::ABSENT_VERSION for overrides the page showed as not stored).
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

    # This namespace's change log, newest first. `key:` filters to one dial.
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
    # otherwise): pass the override's token from ns.overview (or a
    # previous CAS write; Dials::ABSENT_VERSION when the page showed no
    # override) and the write is refused with StaleWrite — unapplied,
    # unlogged — if that override has changed since. A CAS write returns the
    # override's NEW token (chain it into the next write); an unconditional
    # write returns the value, as always.
    def set(key, value, actor:, scope: nil, expected_version: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor, config)
      definition.validate_value!(value)

      if scope.nil? || scope.empty?
        canonical = Scope::GLOBAL
      else
        raise InvalidScope, "dial #{definition.key} declares no dimensions" unless definition.dimensions?

        normalized = Scope.validate!(definition, scope, exact: true)
        canonical = Scope.canonical(normalized)
      end
      _old, written = store.set_override(definition.key, canonical, value, actor_attrs,
                                         expected_version: expected_version)

      after_write
      # The token comes from the write we KNOW happened — never from a
      # second read a concurrent writer could slip in front of.
      expected_version ? StoreVersion.token(written) : value
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
    # tombstone's token instead of the boolean (chainable: a later set
    # carrying it succeeds; an "absent" assertion from an older page does
    # not — cleared is not the same as never-written).
    def clear(key, actor:, scope: nil, expected_version: nil)
      definition = registry.fetch(key)
      actor_attrs = Actor.normalize(actor, config)

      if scope.nil? || scope.empty?
        canonical = Scope::GLOBAL
      else
        normalized = Scope.validate!(definition, scope, exact: true)
        canonical = Scope.canonical(normalized)
      end
      removed, written = store.clear_override(definition.key, canonical, actor_attrs,
                                              expected_version: expected_version)

      after_write
      expected_version ? StoreVersion.token(written) : removed
    end

    # -- test overrides ------------------------------------------------------

    # Pin this namespace's dial values for the duration of a block, without
    # touching the store, the cache, or the change log — see Testing.
    def with_overrides(overrides, &)
      Testing.with_overrides(overrides, self, &)
    end

    def adopt(child)
      @children << child
    end

    protected attr_reader :storage

    # Internal: this namespace reads its parent's cache_ttl, so a change
    # there reaches a cache that was already built.
    def inherit_cache_ttl
      return if config.explicitly_set?(:cache_ttl)

      @cache&.ttl = config.cache_ttl
    end

    def inherit_store
      return if @storage.declared?

      @storage.discard_store!
      reset_cache!
    end

    private

    def collision_owners
      root? ? { "Dials" => Dials, "Dials.default" => self } : { "Dials.namespace(:#{@name})" => self }
    end

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
      Thread.current[@txn_write_key] = true
      store.after_commit { cache.bust! } if store.respond_to?(:after_commit)
    end

    def current_snapshot
      if Thread.current[@txn_write_key]
        return cache.uncached_snapshot if store_transaction_open?

        # The transaction closed (committed or rolled back). Rejoin the
        # shared cache, busting first so the next snapshot reflects the
        # outcome rather than anything published mid-transaction.
        Thread.current[@txn_write_key] = nil
        cache.bust!
      end

      cache.snapshot
    end

    def store_transaction_open?
      s = store
      s.respond_to?(:transaction_open?) && s.transaction_open?
    end
  end
end

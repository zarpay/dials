# frozen_string_literal: true

module Dials
  # One namespace's options, set once at boot via Dials.configure (the root)
  # or the block Dials.namespace takes.
  #
  # An option a namespace does not set reads through to the root's: an engine
  # that configures nothing but its store still honours the app's cache_ttl,
  # actor_label, and default_actor. Where the namespace's values live is the
  # one option with rules of its own — see Storage.
  class Config
    def initialize(namespace, storage, parent: nil)
      @namespace = namespace
      @storage = storage
      @parent = parent
      @explicit = {}
      @label = nil
    end

    # Seconds between staleness probes (see Cache). 0 probes every read;
    # nil never probes.
    def cache_ttl
      inherited_option(:cache_ttl) { 5.0 }
    end

    # Builds the human label stored on every change-log entry.
    def actor_label
      inherited_option(:actor_label) { Actor::DEFAULT_LABEL }
    end

    # Fallback attribution for writes that pass no actor: — for apps without
    # user identity (no User model, single-operator tools, scripts). A
    # string/object, or a callable evaluated per write
    # (`-> { ENV.fetch("USER", "console") }`). nil (the default) keeps
    # actor: required on every write. This is a declared app-level fallback,
    # not discovery — the gem still never guesses (no Current.user magic),
    # and an explicit actor: always wins.
    def default_actor
      inherited_option(:default_actor) { nil }
    end

    # How this namespace is named on an admin surface. Never inherited —
    # every namespace needs a name of its own.
    def label
      @label || @namespace.default_label
    end

    attr_writer :label

    def cache_ttl=(seconds)
      @explicit[:cache_ttl] = seconds
      @namespace.apply_cache_ttl
    end

    def actor_label=(builder)
      @explicit[:actor_label] = builder
    end

    def default_actor=(actor)
      @explicit[:default_actor] = actor
    end

    # True when this config declares the option itself rather than reading
    # the root's.
    def explicitly_set?(option)
      @explicit.key?(option)
    end

    # -- storage -------------------------------------------------------------

    # Accepts a store instance, or the symbols :memory / :active_record.
    def store=(store)
      @storage.kind = store
      @namespace.apply_store
    end

    def store
      @storage.store
    end

    # The table this namespace's ActiveRecord store owns; a namespace never
    # shares one.
    def table_name
      @storage.table_name
    end

    def table_name=(name)
      @storage.table_name = name
      @namespace.reset_cache!
    end

    # Prefix for the ROOT's table, mirroring Rails' table_name_prefix
    # convention: used verbatim, so include the trailing underscore
    # ("ops_" makes the table "ops_dials"). nil (the default) keeps "dials".
    # Set it when "dials" collides with an existing table, and pass the same
    # prefix to the install generator (--table-name-prefix) so the migration
    # matches. A non-root namespace names its table with table_name instead.
    def table_name_prefix
      @storage.table_name_prefix
    end

    def table_name_prefix=(prefix)
      unless @namespace.root?
        raise Error, "table_name_prefix names the root's table; namespace #{@namespace.name} " \
                     "names its own with config.table_name"
      end

      @storage.table_name_prefix = prefix
      @namespace.reset_cache!
    end

    private

    def inherited_option(name)
      return @explicit[name] if @explicit.key?(name)
      return @parent.public_send(name) if @parent

      yield
    end
  end
end

# frozen_string_literal: true

module Dials
  # One namespace's configuration, set once at boot via Dials.configure (the
  # root) or the block Dials.namespace takes.
  #
  # A namespace's unset options read through to the root's: an engine that
  # configures nothing but its store still honours the app's cache_ttl,
  # actor_label, and default_actor. `store` inherits by KIND, never by
  # object — inheriting the root's :active_record store means "an
  # ActiveRecord store of my own table", because a namespace owns its rows.
  # A store OBJECT cannot be inherited at all: sharing one would put two
  # namespaces in one key space, so a namespace under a store object must
  # name its own store.
  class Config
    DEFAULTS = { cache_ttl: 5.0, actor_label: Actor::DEFAULT_LABEL, default_actor: nil }.freeze

    # The root's table, and the suffix every other namespace's table carries.
    DEFAULT_TABLE_NAME = "dials"

    def initialize(namespace, parent: nil)
      @namespace = namespace
      @parent = parent
      @explicit = {}
      @store = nil
      @label = nil
      @table_name = nil
      @table_name_prefix = nil
    end

    # Seconds between staleness probes (see Cache). 0 probes every read;
    # nil never probes.
    def cache_ttl
      inherited_option(:cache_ttl)
    end

    # Builds the human label stored on every change-log entry.
    def actor_label
      inherited_option(:actor_label)
    end

    # Fallback attribution for writes that pass no actor: — for apps without
    # user identity (no User model, single-operator tools, scripts). A
    # string/object, or a callable evaluated per write
    # (`-> { ENV.fetch("USER", "console") }`). nil (the default) keeps
    # actor: required on every write. This is a declared app-level fallback,
    # not discovery — the gem still never guesses (no Current.user magic),
    # and an explicit actor: always wins.
    def default_actor
      inherited_option(:default_actor)
    end

    # How this namespace is named on an admin surface. Never inherited —
    # every namespace needs a name of its own.
    def label
      @label || @namespace.default_label
    end

    attr_writer :label

    # Prefix for the ROOT's table, mirroring Rails' table_name_prefix
    # convention: used verbatim, so include the trailing underscore
    # ("ops_" makes the table "ops_dials"). nil (the default) keeps "dials".
    # Set it when "dials" collides with an existing table, and pass the same
    # prefix to the install generator (--table-name-prefix) so the migration
    # matches. A non-root namespace names its table with table_name instead.
    attr_reader :table_name_prefix

    # The table this namespace's ActiveRecord store owns; a namespace never
    # shares one.
    def table_name
      return @table_name if @table_name
      return "#{@table_name_prefix}#{DEFAULT_TABLE_NAME}" if @namespace.root?

      "#{@namespace.name}_#{DEFAULT_TABLE_NAME}"
    end

    # Both name setters are order-independent with store=: whichever runs
    # second applies the name.
    def table_name=(name)
      @table_name = name
      rename_table
      @namespace.reset_cache!
    end

    def table_name_prefix=(prefix)
      unless @namespace.root?
        raise Error, "table_name_prefix names the root's table; namespace #{@namespace.name} " \
                     "names its own with config.table_name"
      end

      @table_name_prefix = prefix
      rename_table
      @namespace.reset_cache!
    end

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

    # Accepts a store instance, or the symbols :memory / :active_record.
    def store=(store)
      @explicit[:store_kind] = store
      @store = build_store(store)
      @namespace.apply_store
    end

    def store
      @store ||= build_store(store_kind)
    end

    def explicitly_set?(option)
      @explicit.key?(option)
    end

    # Internal; see Namespace#apply_store.
    def discard_store!
      @store = nil
    end

    protected

    # What a child namespace inherits when it declares no store of its own.
    def store_kind
      return @explicit[:store_kind] if @explicit.key?(:store_kind)
      return :memory unless @parent

      inherited = @parent.store_kind
      return inherited if inherited.is_a?(Symbol)

      raise Error, "namespace #{@namespace.name} cannot inherit a store object " \
                   "(two namespaces sharing one store share its rows); set config.store for it"
    end

    private

    def inherited_option(name)
      return @explicit[name] if @explicit.key?(name)
      return @parent.public_send(name) if @parent

      DEFAULTS[name]
    end

    def build_store(kind)
      case kind
      when :memory then Stores::Memory.new
      when :active_record
        require "dials/active_record"
        Stores::ActiveRecordStore.new(model: active_record_model)
      else kind
      end
    end

    # The root keeps the well-known Dials::ActiveRecord::Entry; every other
    # namespace gets a model class of its own, because its rows live in its
    # own table.
    def active_record_model
      model = @namespace.root? ? Dials::ActiveRecord::Entry : Dials::ActiveRecord.model(@namespace.name)
      model.table_name = table_name
      model
    end

    # Renaming the root's table renames the model other code already holds
    # (Dials::ActiveRecord::Entry, since 0.2.0). Any other namespace has no
    # such published constant, so dropping the store is enough — the next
    # read builds one whose model carries the new name.
    def rename_table
      if @namespace.root?
        Dials::ActiveRecord::Entry.table_name = table_name if defined?(Dials::ActiveRecord::Entry)
      else
        @store = nil
      end
    end
  end
end

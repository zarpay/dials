# frozen_string_literal: true

module Dials
  # Where one namespace's values live: the kind of store, the table the
  # namespace owns, and the store object built from the two.
  #
  # A namespace owns its rows, so a namespace that declares no kind inherits
  # the root's KIND and gets a table of its own. A store OBJECT is never
  # inherited: two namespaces on one store would share its key space, so a
  # namespace under a store object must name its own.
  class Storage
    # The root's table, and the suffix every other namespace's table carries.
    DEFAULT_TABLE_NAME = "dials"

    attr_reader :table_name_prefix

    def initialize(namespace, parent: nil)
      @namespace = namespace
      @parent = parent
      @kind = nil
      @declared = false
      @store = nil
      @table_name = nil
      @table_name_prefix = nil
    end

    # A store instance, or the symbols :memory / :active_record.
    def kind=(kind)
      @declared = true
      @kind = kind
      @store = build_store(kind)
    end

    # False when this storage reads the root's kind rather than naming one.
    def declared?
      @declared
    end

    def store
      @store ||= build_store(kind)
    end

    # Drop the built store: the next read builds one from the current kind
    # and table name.
    def discard_store!
      @store = nil
    end

    # The prefixed "dials" for the root, "<name>_dials" for every other
    # namespace, or whatever table_name= says.
    def table_name
      return @table_name if @table_name
      return "#{@table_name_prefix}#{DEFAULT_TABLE_NAME}" if @namespace.root?

      "#{@namespace.name}_#{DEFAULT_TABLE_NAME}"
    end

    # Both name setters are order-independent with kind=: whichever runs
    # second applies the name.
    def table_name=(name)
      @table_name = name
      rename_table
    end

    def table_name_prefix=(prefix)
      @table_name_prefix = prefix
      rename_table
    end

    protected

    # What a namespace's storage inherits when it declares no kind of its own.
    def kind
      return @kind if @declared
      return :memory unless @parent

      inherited = @parent.kind
      return inherited if inherited.is_a?(Symbol)

      raise Error, "namespace #{@namespace.name} cannot inherit a store object " \
                   "(two namespaces sharing one store share its rows); set config.store for it"
    end

    private

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
        discard_store!
      end
    end
  end
end

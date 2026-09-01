# frozen_string_literal: true

module Dials
  # An immutable point-in-time copy of every stored override.
  #
  #   globals::    { key(Symbol) => value } — only dials with a stored global
  #                override appear; absence means "inherit the code default".
  #   scoped_overrides:: { key(Symbol) => { canonical_scope(String) => value } }
  #   row_versions:: { key(Symbol) => { canonical_scope(String) => Integer } }
  #                — the per-override version stamps (the global's under
  #                Scope::GLOBAL), for stale-write tokens.
  #   version::    the store's monotonic write counter at load time.
  #
  # Values are deep-frozen: reads hand out references into the shared
  # snapshot, and a caller mutating a returned :json value must not be able
  # to corrupt what every other thread reads.
  class Snapshot
    attr_reader :globals, :scoped_overrides, :row_versions, :version

    def initialize(globals:, scoped_overrides:, version:, row_versions: {})
      @globals = Freeze.deep(globals)
      @scoped_overrides = Freeze.deep(scoped_overrides)
      @row_versions = Freeze.deep(row_versions)
      @version = version
      freeze
    end
  end

  Snapshot::EMPTY = Snapshot.new(globals: {}, scoped_overrides: {}, version: 0)
end

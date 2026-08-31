# frozen_string_literal: true

module Dials
  # An immutable point-in-time copy of every stored override.
  #
  #   globals::    { key(Symbol) => value } — only dials with a stored global
  #                override appear; absence means "inherit the code default".
  #   variations:: { key(Symbol) => { canonical_scope(String) => value } }
  #   version::    the store's monotonic write counter at load time.
  #
  # Values are deep-frozen: reads hand out references into the shared
  # snapshot, and a caller mutating a returned :json value must not be able
  # to corrupt what every other thread reads.
  class Snapshot
    attr_reader :globals, :variations, :version

    def initialize(globals:, variations:, version:)
      @globals = Freeze.deep(globals)
      @variations = Freeze.deep(variations)
      @version = version
      freeze
    end
  end

  Snapshot::EMPTY = Snapshot.new(globals: {}, variations: {}, version: 0)
end

# frozen_string_literal: true

module Dials
  # The in-code catalog of every dial the application declares. A key's
  # presence here is what makes it a dial at all: reads, writes, and scope
  # validation all consult the registry, and an admin surface renders exactly
  # these entries.
  #
  # Declarations accumulate across `Dials.define` blocks (so large apps can
  # split declarations by domain), but a key declared twice raises — a dial's
  # declaration is its single source of truth.
  class Registry
    include Enumerable

    def initialize
      @definitions = {}
      @mutex = Mutex.new
    end

    # DSL entry point used by `Dials.define { dial ... }`. Registering a key
    # also generates its per-dial methods (the Dials.<key> reader and the
    # adjust_/clear_ writers);
    # Generated.install! checks for name collisions before defining anything,
    # so a raise here leaves neither a definition nor a stray method behind.
    def dial(key, **)
      definition = Definition.new(key, **)
      @mutex.synchronize do
        raise DuplicateDial, "dial #{definition.key} is already defined" if @definitions.key?(definition.key)

        Generated.install!(definition)
        @definitions[definition.key] = definition
      end
      definition
    end

    def fetch(key)
      @definitions.fetch(key.to_sym) do
        raise UnknownDial, "no dial defined for #{key.inspect} (defined: #{keys.join(', ')})"
      end
    end

    def defined?(key)
      @definitions.key?(key.to_sym)
    end

    def keys
      @definitions.keys
    end

    def each(&)
      @definitions.values.each(&)
    end

    def all
      @definitions.values
    end

    # Test hook: wipe every declaration and its generated methods. Production
    # code has no reason to call this; a registry that shrinks at runtime
    # would strand stored rows.
    def reset!
      @mutex.synchronize do
        @definitions.clear
        Generated.uninstall_all!
      end
    end
  end
end

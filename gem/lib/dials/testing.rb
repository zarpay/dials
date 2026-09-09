# frozen_string_literal: true

module Dials
  # Test-override mechanics. `with_overrides` pins dial values for the
  # duration of a block without touching the store, the cache, or the change
  # log — reads inside the block (on the same thread) see the pinned value for
  # every scope of that dial. Nesting composes; inner blocks win.
  #
  #   Dials::Testing.with_overrides(merchant_fee_bps: 250) do
  #     Dials.merchant_fee_bps(market: "KE") # => 250
  #   end
  #
  # Values are validated against the dial's declaration, so a test cannot
  # pin a value production could never hold.
  #
  # Pins belong to ONE namespace: they are keyed by its name, so pinning the
  # app's :timeout_seconds leaves an engine's dial of the same name resolving
  # normally. `Dials::Testing.with_overrides` pins the default namespace;
  # every namespace also pins through itself (`Shipping.with_overrides`).
  module Testing
    module_function

    def with_overrides(overrides, namespace = Dials.default)
      validated = overrides.to_h do |key, value|
        definition = namespace.registry.fetch(key)
        [definition.key, definition.validate_value!(value)]
      end

      thread_key = thread_key_for(namespace)
      previous = Thread.current[thread_key]
      Thread.current[thread_key] = (previous || {}).merge(validated)
      yield
    ensure
      # thread_key is nil when validation raised — nothing was pinned, and
      # restoring must not mask the caller's error.
      Thread.current[thread_key] = previous if thread_key
    end

    # One dial's pin, wrapped in an array so a pinned `false` is still a pin;
    # nil when the dial is not pinned. Called on every read.
    def override_for(namespace, key)
      overrides = Thread.current[thread_key_for(namespace)]
      return nil unless overrides

      overrides.key?(key) ? [overrides[key]] : nil
    end

    def thread_key_for(namespace)
      :"dials_testing_overrides_#{namespace.name}"
    end
  end
end

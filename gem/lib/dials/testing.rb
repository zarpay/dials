# frozen_string_literal: true

module Dials
  # Test helpers. `with_overrides` pins dial values for the duration of a
  # block without touching the store, the cache, or the change log — reads
  # inside the block (on the same thread) see the pinned value for every
  # scope of that dial. Nesting composes; inner blocks win.
  #
  #   Dials::Testing.with_overrides(merchant_fee_bps: 250) do
  #     Dials.use_merchant_fee_bps(market: "KE") # => 250
  #   end
  #
  # Values are validated against the dial's declaration, so a test cannot
  # pin a value production could never hold.
  module Testing
    THREAD_KEY = :dials_testing_overrides

    module_function

    def with_overrides(overrides)
      validated = overrides.to_h do |key, value|
        definition = Dials.registry.fetch(key)
        [definition.key, definition.validate_value!(value)]
      end

      previous = Thread.current[THREAD_KEY]
      Thread.current[THREAD_KEY] = (previous || {}).merge(validated)
      yield
    ensure
      Thread.current[THREAD_KEY] = previous
    end

    def override_for(key)
      overrides = Thread.current[THREAD_KEY]
      return nil unless overrides

      overrides.key?(key) ? [overrides[key]] : nil
    end
  end
end

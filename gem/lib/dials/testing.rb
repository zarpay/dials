# frozen_string_literal: true

module Dials
  # Test helpers for the default namespace. `with_overrides` pins dial values
  # for the duration of a block without touching the store, the cache, or the
  # change log — reads inside the block (on the same thread) see the pinned
  # value for every scope of that dial. Nesting composes; inner blocks win.
  #
  #   Dials::Testing.with_overrides(merchant_fee_bps: 250) do
  #     Dials.merchant_fee_bps(market: "KE") # => 250
  #   end
  #
  # Values are validated against the dial's declaration, so a test cannot
  # pin a value production could never hold.
  #
  # Another namespace pins its own dials through itself:
  # `Transfers.with_overrides(...)`.
  module Testing
    module_function

    def with_overrides(overrides, &)
      Dials.default.with_overrides(overrides, &)
    end
  end
end

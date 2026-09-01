# frozen_string_literal: true

module Dials
  # The store's write counter as an opaque token (a frozen String, safe to
  # round-trip through JSON, HTML forms, and HTTP params). Callers obtain a
  # token from Dials.overview (or as the return value of a write that carried
  # `expected_version:`) and echo it back on writes — they never construct or
  # parse one, so the internal representation stays free to change.
  #
  # Comparison is plain string equality: a store checks
  # `StoreVersion.token(current) == expected`. A token from a different store
  # shape (or garbage) simply never matches and surfaces as StaleWrite — the
  # safe direction.
  module StoreVersion
    module_function

    def token(raw)
      JSON.generate(raw).freeze
    end
  end
end

# frozen_string_literal: true

module Dials
  # Per-override version tokens (opaque frozen Strings, safe to round-trip
  # through JSON, HTML forms, and HTTP params). Every stored override row
  # carries a version stamped from its last change-log entry — monotonic
  # across the whole store, so a row deleted and re-created can never revisit
  # an old version (no ABA). "No override" has the well-known token ABSENT.
  #
  # Callers obtain tokens from Dials.overview (or as the return value of a
  # write that carried `expected_version:`) and echo them back on writes —
  # they never construct or parse one, so the representation stays free to
  # change. Comparison is plain string equality; a token from a different
  # store shape (or garbage) simply never matches and surfaces as StaleWrite,
  # the safe direction.
  module StoreVersion
    module_function

    def token(raw)
      JSON.generate(raw).freeze
    end

    # The token of a row that does not exist. Passing it as expected_version:
    # means "I saw no override here" — the write succeeds only if that is
    # still true.
    ABSENT = token(0)
  end
end

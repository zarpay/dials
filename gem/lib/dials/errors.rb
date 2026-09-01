# frozen_string_literal: true

module Dials
  # Base class for every error the gem raises deliberately.
  class Error < StandardError; end

  # Raised when a key is read or written that no `dial` declaration defined.
  class UnknownDial < Error; end

  # Raised when the same key is declared twice. A dial's declaration is its
  # identity; a silent second declaration would make "which bounds apply?"
  # ambiguous.
  class DuplicateDial < Error; end

  # Raised when a definition itself is malformed (bad type, bad variants
  # shape, unknown schema keyword, default that fails its own schema).
  # Definitions fail at boot, not at first read in production.
  class InvalidDefinition < Error; end

  # Raised when a candidate value is not storable for its dial: wrong type,
  # schema violation, or nil (nil is never a value — use clear to remove an
  # override).
  class InvalidValue < Error; end

  # Raised when a scope does not match the dial's declared variant
  # dimensions: unknown dimension, missing dimension, or a value outside a
  # dimension's declared options. Also raised when a scope is given for a
  # dial that declares no variants at all.
  class InvalidScope < Error; end

  # Raised when a write arrives without an actor. Every write is attributed;
  # there is no anonymous mutation path through the public API.
  class MissingActor < Error; end

  # Raised when a write carries `expected_version:` and the store has moved
  # past that version — the caller acted on a stale picture. The write is
  # not applied and nothing is appended to the change log. Deliberately NOT
  # retried by the stores (a retried compare-and-swap would recompute
  # against the new version and succeed, silently defeating the mechanism):
  # the surface should re-render from Dials.overview and let the operator
  # decide again.
  class StaleWrite < Error; end
end

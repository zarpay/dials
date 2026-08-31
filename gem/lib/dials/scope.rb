# frozen_string_literal: true

require "json"

module Dials
  # Scope handling: validation against a dial's declared dimensions and a
  # canonical string form for storage and lookup.
  #
  # The canonical form is a JSON object with sorted keys and string values —
  # `{market: :KE}` and `{"market" => "KE"}` both canonicalize to
  # `{"market":"KE"}` — so a scope written once can never be re-stored under a
  # cosmetically different spelling. Uniqueness lives on (dial, canonical
  # scope) in whatever store persists it.
  #
  # v1 write rule: a variation's scope names ALL of its dial's declared
  # dimensions (exact scope). The matching code in Resolver is already
  # general (subset match, most-specific wins), so partial scopes are a
  # planned write-side relaxation, not a redesign. See docs/design.
  module Scope
    module_function

    # Normalize a caller-supplied scope hash into {symbol => string}. A hash
    # naming the same dimension twice under different spellings
    # ({"market" => "KE", market: "NG"}) is a caller bug — one value would
    # silently win by insertion order — so it raises instead.
    def normalize(scope)
      scope ||= {}
      normalized = scope.to_h { |k, v| [k.to_sym, v.to_s] }
      if normalized.size != scope.size
        raise InvalidScope, "scope names the same dimension more than once: #{scope.keys.inspect}"
      end

      normalized
    end

    # Stored canonical scopes land in an indexed VARCHAR(255); a longer
    # string would fail (or truncate and collide) at the database on some
    # adapters, so it fails validation here instead.
    MAX_CANONICAL_BYTES = 255

    # Canonical storage/lookup string for a normalized scope.
    def canonical(scope)
      result = JSON.generate(normalize(scope).sort.to_h { |k, v| [k.to_s, v] })
      if result.bytesize > MAX_CANONICAL_BYTES
        raise InvalidScope, "canonical scope exceeds #{MAX_CANONICAL_BYTES} bytes: #{result[0, 80]}…"
      end

      result
    end

    # Inverse of .canonical — used when loading stored rows. A stored scope
    # that is valid JSON but not an object ("42", "[]") is corrupt data, not
    # a scope; raising InvalidScope lets loaders quarantine the row.
    def parse(canonical_string)
      parsed = JSON.parse(canonical_string)
      raise InvalidScope, "stored scope is not a JSON object: #{canonical_string.inspect}" unless parsed.is_a?(Hash)

      parsed.to_h { |k, v| [k.to_sym, v] }
    end

    # Validate a scope against a definition. `exact:` requires every declared
    # dimension to be present (the v1 rule for both reads and writes);
    # without it, any subset of declared dimensions passes (the future
    # partial-scope rule). Raises InvalidScope; returns the normalized hash.
    def validate!(definition, scope, exact: true)
      normalized = normalize(scope)

      if definition.dimensions.empty?
        return normalized if normalized.empty?

        raise InvalidScope, "dial #{definition.key} declares no variants; scope #{normalized.inspect} is not allowed"
      end

      declared = definition.dimensions.to_h { |d| [d.name, d] }

      normalized.each_key do |name|
        next if declared.key?(name)

        raise InvalidScope, "dial #{definition.key} has no dimension #{name} (declares: #{declared.keys.join(', ')})"
      end

      if exact
        missing = declared.keys - normalized.keys
        unless missing.empty?
          raise InvalidScope, "dial #{definition.key} requires scope for: #{missing.join(', ')}"
        end
      end

      normalized.each do |name, value|
        dimension = declared.fetch(name)
        next if dimension.valid_value?(value)

        raise InvalidScope, "#{value.inspect} is not a valid #{name} for dial #{definition.key}"
      end

      normalized
    end
  end
end

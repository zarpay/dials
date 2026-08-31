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

    # Normalize a caller-supplied scope hash into {symbol => string}.
    def normalize(scope)
      (scope || {}).to_h { |k, v| [k.to_sym, v.to_s] }
    end

    # Canonical storage/lookup string for a normalized scope.
    def canonical(scope)
      JSON.generate(normalize(scope).sort.to_h { |k, v| [k.to_s, v] })
    end

    # Inverse of .canonical — used when loading stored rows.
    def parse(canonical_string)
      JSON.parse(canonical_string).to_h { |k, v| [k.to_sym, v] }
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

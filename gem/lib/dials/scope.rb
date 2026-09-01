# frozen_string_literal: true

require "json"

module Dials
  # A scope names variant dimensions — `{market: "KE"}`. The empty scope is
  # the global one.
  #
  # Scopes are stored as canonical JSON: sorted string keys, string values.
  # `{market: :KE}` and `{"market" => "KE"}` therefore land on the same row,
  # so one thing can never be overridden twice under two spellings.
  module Scope
    # The stored column is an indexed string. A longer scope would truncate
    # (and then collide) on some adapters, so it fails here instead.
    MAX_BYTES = 255

    module_function

    def normalize(scope)
      normalized = scope.to_h { |name, value| [name.to_sym, value.to_s] }
      raise InvalidScope, "scope names a dimension twice: #{scope.keys.inspect}" if normalized.size != scope.size

      normalized
    end

    def dump(scope)
      json = JSON.generate(normalize(scope).sort.to_h { |name, value| [name.to_s, value] })
      raise InvalidScope, "scope is longer than #{MAX_BYTES} bytes: #{json[0, 60]}…" if json.bytesize > MAX_BYTES

      json
    end

    def load(json)
      parsed = JSON.parse(json)
      raise InvalidScope, "stored scope is not a JSON object: #{json.inspect}" unless parsed.is_a?(Hash)

      parsed.transform_keys(&:to_sym)
    end
  end
end

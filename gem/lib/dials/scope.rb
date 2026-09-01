# frozen_string_literal: true

require "json"

module Dials
  # A scope names dimensions — `{market: "KE"}`. The empty scope is
  # the global one.
  #
  # Scopes are stored as canonical JSON: sorted string keys, string values.
  # `{market: :KE}` and `{"market" => "KE"}` therefore land on the same row,
  # so one thing can never be overridden twice under two spellings.
  module Scope
    # The stored column is an indexed string. A longer scope would truncate
    # (and then collide) on some adapters, so it fails here instead.
    MAX_BYTES = 255

    # One dimension's value. Well under MAX_BYTES so a scope naming several
    # dimensions still fits.
    MAX_VALUE_BYTES = 128

    module_function

    def normalize(scope)
      # The modal read names no scope at all; skip building a hash to say so.
      return scope if scope.empty?

      normalized = scope.to_h { |name, value| [name.to_sym, value.to_s] }
      raise InvalidScope, "scope names a dimension twice: #{scope.keys.inspect}" if normalized.size != scope.size

      normalized.each do |name, value|
        # An empty value is almost always a missing one — `market: params[:market]`
        # with no param gives "". Reading the global instead of saying so would
        # be a wrong answer delivered quietly.
        raise InvalidScope, "#{name} is empty (a missing value must not read as the global)" if value.empty?
        raise InvalidScope, "#{name} is longer than #{MAX_VALUE_BYTES} bytes" if value.bytesize > MAX_VALUE_BYTES
      end

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

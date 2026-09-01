# frozen_string_literal: true

module Dials
  # One variant dimension of a dial: a name (:market, :platform, ...) and an
  # optional set of allowed values — `enum`, the same word JSON Schema and
  # the dial value constraints use. The enum may be given as an Array or as a
  # callable (for values that are expensive to build or defined elsewhere,
  # e.g. `-> { ISO3166::Country.codes }`); a callable is resolved once, on
  # first use, under a lock (so a stateful or expensive callable cannot be
  # raced into running twice by concurrent first reads).
  #
  # Dimension values are always compared as strings — "KE" and :KE name the
  # same market. A dimension without an enum accepts any non-empty string up
  # to MAX_VALUE_LENGTH characters (canonical scopes land in an indexed
  # VARCHAR column; unbounded values would overflow or collide there).
  class Dimension
    MAX_VALUE_LENGTH = 128

    attr_reader :name

    def initialize(name, enum: nil)
      @name = name.to_sym
      @raw_enum = enum
      @enum = nil
      @mutex = Mutex.new
      validate_shape!
    end

    # Allowed values as an Array of strings, or nil when the dimension is
    # open (accepts any value).
    def enum
      return nil if @raw_enum.nil?

      # Double-checked so the hot read path (every scope validation) skips
      # the mutex once resolved.
      resolved = @enum
      return resolved if resolved

      @mutex.synchronize do
        @enum ||= Array(@raw_enum.respond_to?(:call) ? @raw_enum.call : @raw_enum)
                  .map { |o| o.to_s.freeze }.freeze
      end
    end

    def valid_value?(value)
      value = value.to_s
      return false if value.empty? || value.length > MAX_VALUE_LENGTH

      enum.nil? || enum.include?(value)
    end

    private

    def validate_shape!
      return if @raw_enum.nil? || @raw_enum.is_a?(Array) || @raw_enum.respond_to?(:call)

      raise InvalidDefinition, "dimension #{@name}: enum must be an Array or a callable, got #{@raw_enum.class}"
    end
  end
end

# frozen_string_literal: true

module Dials
  # One variant dimension of a dial: a name (:market, :platform, ...) and an
  # optional set of allowed values. Options may be given as an Array or as a
  # callable (for values that are expensive to build or defined elsewhere,
  # e.g. `-> { ISO3166::Country.codes }`); a callable is resolved once, on
  # first use, under a lock (so a stateful or expensive callable cannot be
  # raced into running twice by concurrent first reads).
  #
  # Dimension values are always compared as strings — "KE" and :KE name the
  # same market. A dimension without options accepts any non-empty string up
  # to MAX_VALUE_LENGTH characters (canonical scopes land in an indexed
  # VARCHAR column; unbounded values would overflow or collide there).
  class Dimension
    MAX_VALUE_LENGTH = 128

    attr_reader :name

    def initialize(name, options: nil)
      @name = name.to_sym
      @raw_options = options
      @options = nil
      @mutex = Mutex.new
      validate_shape!
    end

    # Allowed values as an Array of strings, or nil when the dimension is
    # open (accepts any value).
    def options
      return nil if @raw_options.nil?

      # Double-checked so the hot read path (every scope validation) skips
      # the mutex once resolved.
      resolved = @options
      return resolved if resolved

      @mutex.synchronize do
        @options ||= Array(@raw_options.respond_to?(:call) ? @raw_options.call : @raw_options)
                     .map { |o| o.to_s.freeze }.freeze
      end
    end

    def valid_value?(value)
      value = value.to_s
      return false if value.empty? || value.length > MAX_VALUE_LENGTH

      options.nil? || options.include?(value)
    end

    private

    def validate_shape!
      return if @raw_options.nil? || @raw_options.is_a?(Array) || @raw_options.respond_to?(:call)

      raise InvalidDefinition, "dimension #{@name}: options must be an Array or a callable, got #{@raw_options.class}"
    end
  end
end

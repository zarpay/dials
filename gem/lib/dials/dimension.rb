# frozen_string_literal: true

module Dials
  # One variant dimension of a dial: a name (:market, :platform, ...) and an
  # optional set of allowed values. Options may be given as an Array or as a
  # callable (for values that are expensive to build or defined elsewhere,
  # e.g. `-> { ISO3166::Country.codes }`); a callable is resolved once, on
  # first use.
  #
  # Dimension values are always compared as strings — "KE" and :KE name the
  # same market. A dimension without options accepts any non-empty string.
  class Dimension
    attr_reader :name

    def initialize(name, options: nil)
      @name = name.to_sym
      @raw_options = options
      @resolved = nil
      validate_shape!
    end

    # Allowed values as an Array of strings, or nil when the dimension is
    # open (accepts any value).
    def options
      return nil if @raw_options.nil?

      @options ||= Array(@raw_options.respond_to?(:call) ? @raw_options.call : @raw_options).map(&:to_s).freeze
    end

    def valid_value?(value)
      value = value.to_s
      return false if value.empty?

      options.nil? || options.include?(value)
    end

    private

    def validate_shape!
      return if @raw_options.nil? || @raw_options.is_a?(Array) || @raw_options.respond_to?(:call)

      raise InvalidDefinition, "dimension #{@name}: options must be an Array or a callable, got #{@raw_options.class}"
    end
  end
end

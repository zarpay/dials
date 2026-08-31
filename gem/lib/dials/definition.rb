# frozen_string_literal: true

module Dials
  # A dial's declaration: its identity, its code default, and the rules a
  # stored value must satisfy. Definitions live in code (the registry), never
  # in the database — the database stores only values.
  #
  # type::   :boolean, :integer, :float, :string, or :json (any
  #          JSON-serializable structure).
  # bounds:: optional constraint on top of the type — a Range (`1..10_000`),
  #          an Array of allowed values (`%w[low medium high]`), or a callable
  #          returning truthy when the value is storable.
  # variants:: the dial's variant dimensions. Declaring variants is the
  #          arming gate: a dial with none is global-only by construction,
  #          and adding the declaration belongs in the same change as the
  #          code that reads the varied value.
  class Definition
    TYPES = %i[boolean integer float string json].freeze

    attr_reader :key, :default, :type, :label, :unit, :description, :dimensions

    def initialize(key, default, type:, bounds: nil, label: nil, unit: nil, description: nil, variants: nil)
      @key = key.to_sym
      @type = type.to_sym
      @bounds = bounds
      @label = label || @key.to_s.tr("_", " ").capitalize
      @unit = unit
      @description = description
      @dimensions = build_dimensions(variants)
      @default = default

      validate_definition!
      freeze
    end

    def variants?
      !dimensions.empty?
    end

    def dimension_names
      dimensions.map(&:name)
    end

    # Validation problems for a candidate stored value; [] when storable.
    # `nil` is never storable — removing an override is `Dials.clear`, so a
    # stored nil could only ever be an accident.
    def problems_for(value)
      return ["cannot be nil (use clear to remove an override)"] if value.nil?

      problem = type_problem(value)
      return [problem] if problem

      bounds_problems(value)
    end

    def validate_value!(value)
      problems = problems_for(value)
      return value if problems.empty?

      raise InvalidValue, "#{key}: value #{value.inspect} #{problems.join('; ')}"
    end

    private

    def build_dimensions(variants)
      case variants
      when nil then [].freeze
      when Array
        variants.map { |name| Dimension.new(name) }.freeze
      when Hash
        variants.map do |name, spec|
          spec = { options: spec } if spec.is_a?(Array) || spec.respond_to?(:call)
          Dimension.new(name, options: spec.is_a?(Hash) ? spec[:options] : nil)
        end.freeze
      else
        raise InvalidDefinition, "#{key}: variants must be a Hash or Array, got #{variants.class}"
      end
    end

    def validate_definition!
      raise InvalidDefinition, "#{key}: unknown type #{type.inspect} (use one of #{TYPES.join(', ')})" unless TYPES.include?(type)

      names = dimension_names
      raise InvalidDefinition, "#{key}: duplicate variant dimension" unless names.uniq.length == names.length

      if @bounds && !(@bounds.is_a?(Range) || @bounds.is_a?(Array) || @bounds.respond_to?(:call))
        raise InvalidDefinition, "#{key}: bounds must be a Range, Array, or callable"
      end

      problems = problems_for(default)
      return if problems.empty?

      raise InvalidDefinition, "#{key}: default #{default.inspect} #{problems.join('; ')}"
    end

    def type_problem(value)
      case type
      when :boolean
        # `false` is a first-class storable value. Anything presence-shaped
        # that rejects false makes a kill switch impossible to turn off.
        "must be true or false" unless [true, false].include?(value)
      when :integer
        "must be an integer" unless value.is_a?(Integer)
      when :float
        "must be a number" unless value.is_a?(Numeric) && !value.is_a?(Complex)
      when :string
        "must be a string" unless value.is_a?(String)
      when :json
        json_problem(value)
      end
    end

    def json_problem(value)
      JSON.generate(value)
      nil
    rescue StandardError
      "must be JSON-serializable"
    end

    def bounds_problems(value)
      case @bounds
      when nil then []
      when Range
        @bounds.cover?(value) ? [] : ["must be within #{@bounds}"]
      when Array
        @bounds.include?(value) ? [] : ["must be one of #{@bounds.inspect}"]
      else
        @bounds.call(value) ? [] : ["is out of bounds"]
      end
    end
  end
end

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

    def initialize(key, default:, type:, bounds: nil, label: nil, unit: nil, description: nil, variants: nil)
      @key = key.to_sym
      @type = type.to_sym
      @bounds = bounds
      @label = label || @key.to_s.tr("_", " ").capitalize
      @unit = unit
      @description = description
      @dimensions = build_dimensions(variants)
      @default = default

      # Validate BEFORE freezing: a default that fails validation (including
      # a cyclic structure, which the JSON round-trip rejects) must raise
      # InvalidDefinition without having frozen the caller's object — and
      # Freeze.deep would recurse forever on a cycle.
      validate_definition!

      # Deep-frozen: resolution returns the default directly when nothing is
      # stored, and a caller must not be able to mutate the code default for
      # every other reader in the process.
      @default = Freeze.deep(default)
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
        variants.map { |name, spec| Dimension.new(name, options: dimension_options(name, spec)) }.freeze
      else
        raise InvalidDefinition, "#{key}: variants must be a Hash or Array, got #{variants.class}"
      end
    end

    # Strict on shape: a typo like `{ "options" => [...] }` (string key) or
    # `{ market: "KE" }` must raise, not silently become an OPEN dimension
    # that accepts any value.
    def dimension_options(name, spec)
      case spec
      when nil then nil
      when Hash
        unknown = spec.keys - [:options]
        unless unknown.empty?
          raise InvalidDefinition,
                "#{key}: dimension #{name} has unknown keys #{unknown.inspect} (use options: with a symbol key)"
        end
        spec[:options]
      when Array then spec
      else
        return spec if spec.respond_to?(:call)

        raise InvalidDefinition, "#{key}: dimension #{name} spec must be an Array, a callable, or { options: ... }"
      end
    end

    def validate_definition!
      raise InvalidDefinition, "#{key}: unknown type #{type.inspect} (use one of #{TYPES.join(', ')})" unless TYPES.include?(type)

      names = dimension_names
      raise InvalidDefinition, "#{key}: duplicate variant dimension" unless names.uniq.length == names.length

      # Generated adjust_/clear_ methods take scope as bare keywords next to
      # actor:, so a dimension named actor could never be passed to them.
      if names.include?(:actor)
        raise InvalidDefinition, "#{key}: actor is a reserved dimension name (it means attribution on every write)"
      end

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
        # Only Integer and Float survive a JSON round-trip as numbers —
        # BigDecimal and Rational would come back from the store as strings.
        # Non-finite floats (NaN, Infinity) are not representable in JSON.
        if !(value.is_a?(Integer) || value.is_a?(Float))
          "must be an Integer or Float"
        elsif value.is_a?(Float) && !value.finite?
          "must be finite"
        end
      when :string
        "must be a string" unless value.is_a?(String)
      when :json
        json_problem(value)
      end
    end

    # A :json value must survive the JSON round-trip UNCHANGED. Ruby's JSON
    # generator happily stringifies symbols, Times, and arbitrary objects —
    # which means a write would succeed and the very next read would return
    # a different value. Requiring round-trip equality rejects those at
    # write time (use string keys and JSON-native types).
    def json_problem(value)
      decoded = JSON.parse(JSON.generate(value))
      return nil if decoded == value

      "must round-trip through JSON unchanged (use string keys and JSON-native types)"
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

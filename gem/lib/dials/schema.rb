# frozen_string_literal: true

module Dials
  # A dial's value constraints, spoken in JSON Schema's vocabulary
  # (snake_cased for Ruby): `enum`; `minimum` / `maximum` /
  # `exclusive_minimum` / `exclusive_maximum` / `multiple_of` for numbers;
  # `min_length` / `max_length` / `pattern` for strings; `properties` /
  # `required` for :json objects (with `items` available inside nested array
  # schemas). Borrowing the standard's words means no bespoke vocabulary
  # decisions when the API grows, and constraints are declarative data an
  # admin surface can render — see #to_json_schema. Rules a schema cannot
  # express use the dial's `validate:` callable instead (see Definition).
  #
  # Nested schemas (inside properties/items) must declare a `type:` — the
  # value checks are type-driven, and an untyped nested constraint would
  # silently skip them (JSON Schema's "keywords ignore mismatched types" rule
  # is exactly the footgun this gem's boot-time strictness exists to avoid).
  # For the same reason, declaring `properties`/`required` on a :json dial
  # pins its values to JSON objects.
  class Schema
    NUMERIC_KEYWORDS = %i[minimum maximum exclusive_minimum exclusive_maximum multiple_of].freeze
    STRING_KEYWORDS = %i[min_length max_length pattern].freeze
    OBJECT_KEYWORDS = %i[properties required].freeze

    # Keywords a dial declaration may use, by dial type.
    DIAL_KEYWORDS = {
      boolean: [:enum].freeze,
      integer: ([:enum] + NUMERIC_KEYWORDS).freeze,
      float: ([:enum] + NUMERIC_KEYWORDS).freeze,
      string: ([:enum] + STRING_KEYWORDS).freeze,
      json: ([:enum] + OBJECT_KEYWORDS).freeze
    }.freeze

    # Types and keywords available inside nested schemas. These are JSON
    # Schema's own type names (:number, :object, :array), not the dial types.
    NESTED_KEYWORDS = {
      boolean: [:enum].freeze,
      integer: ([:enum] + NUMERIC_KEYWORDS).freeze,
      number: ([:enum] + NUMERIC_KEYWORDS).freeze,
      string: ([:enum] + STRING_KEYWORDS).freeze,
      object: ([:enum] + OBJECT_KEYWORDS).freeze,
      array: %i[enum items].freeze
    }.freeze

    TYPE_CHECKS = {
      boolean: ["must be true or false", ->(v) { [true, false].include?(v) }].freeze,
      integer: ["must be an integer", ->(v) { v.is_a?(Integer) }].freeze,
      number: ["must be a number", ->(v) { v.is_a?(Integer) || v.is_a?(Float) }].freeze,
      string: ["must be a string", ->(v) { v.is_a?(String) }].freeze,
      object: ["must be a JSON object", ->(v) { v.is_a?(Hash) }].freeze,
      array: ["must be an array", ->(v) { v.is_a?(Array) }].freeze
    }.freeze

    CAMEL = {
      exclusive_minimum: "exclusiveMinimum", exclusive_maximum: "exclusiveMaximum",
      multiple_of: "multipleOf", min_length: "minLength", max_length: "maxLength"
    }.freeze

    def initialize(key, type, constraints)
      @key = key
      @constraints = normalize!(constraints, allowed: DIAL_KEYWORDS.fetch(type), path: nil)
      Freeze.deep(@constraints)
      freeze
    end

    def empty?
      @constraints.empty?
    end

    # True when the schema constrains :json values to objects
    # (properties/required declared) — used for the emitted "type".
    def object?
      @constraints.key?(:properties) || @constraints.key?(:required)
    end

    # Validation problems for a type-checked value; [] when it conforms.
    def problems_for(value)
      problems(@constraints, value, nil)
    end

    # The constraints as a JSON Schema fragment (camelCase keywords, pattern
    # as its regexp source). The dial's `validate:` callable, if any, is not
    # representable here — that is the deal it offers.
    def to_json_schema
      render(@constraints)
    end

    private

    # -- declaration-time normalization --------------------------------------

    def normalize!(constraints, allowed:, path:)
      if constraints.key?(:bounds)
        boom(path, "bounds: was replaced by JSON Schema keywords " \
                   "(minimum:/maximum:/enum:/pattern:/... — validate: for arbitrary rules)")
      end

      unknown = constraints.keys - allowed
      unless unknown.empty?
        boom(path, "unknown keyword#{'s' if unknown.size > 1} #{unknown.join(', ')} " \
                   "(allows: #{allowed.join(', ')})")
      end

      constraints.to_h { |keyword, spec| [keyword, normalize_keyword!(keyword, spec, path)] }
    end

    def normalize_keyword!(keyword, spec, path)
      case keyword
      when :enum
        boom(path, "enum must be a non-empty Array") unless spec.is_a?(Array) && !spec.empty?
        spec.dup
      when :minimum, :maximum, :exclusive_minimum, :exclusive_maximum
        boom(path, "#{keyword} must be a number") unless spec.is_a?(Numeric)
        spec
      when :multiple_of
        boom(path, "multiple_of must be a positive number") unless spec.is_a?(Numeric) && spec.positive?
        spec
      when :min_length, :max_length
        boom(path, "#{keyword} must be a non-negative integer") unless spec.is_a?(Integer) && spec >= 0
        spec
      when :pattern then normalize_pattern!(spec, path)
      when :properties then normalize_properties!(spec, path)
      when :required then normalize_required!(spec, path)
      when :items then normalize_nested!(spec, join(path, "items"))
      end
    end

    def normalize_pattern!(spec, path)
      case spec
      when Regexp then spec
      when String
        begin
          Regexp.new(spec)
        rescue RegexpError => e
          boom(path, "pattern is not a valid regexp (#{e.message})")
        end
      else
        boom(path, "pattern must be a Regexp or String")
      end
    end

    def normalize_properties!(spec, path)
      boom(path, "properties must be a Hash of name => schema") unless spec.is_a?(Hash)

      spec.to_h { |name, sub| [name.to_s, normalize_nested!(sub, join(path, name))] }
    end

    def normalize_required!(spec, path)
      unless spec.is_a?(Array) && spec.all? { |k| k.is_a?(String) || k.is_a?(Symbol) }
        boom(path, "required must be an Array of key names")
      end
      spec.map(&:to_s)
    end

    def normalize_nested!(spec, path)
      boom(path, "schema must be a Hash") unless spec.is_a?(Hash)

      spec = spec.transform_keys(&:to_sym)
      type = spec[:type]&.to_sym
      allowed = NESTED_KEYWORDS.fetch(type) do
        boom(path, "schema needs a type: (one of #{NESTED_KEYWORDS.keys.join(', ')})")
      end

      { type: type }.merge(normalize!(spec.except(:type), allowed: allowed, path: path))
    end

    def join(path, name)
      path ? "#{path}.#{name}" : name.to_s
    end

    def boom(path, message)
      raise InvalidDefinition, ["#{@key}:", path, message].compact.join(" ")
    end

    # -- value validation -----------------------------------------------------

    def problems(cons, value, path)
      if cons[:type]
        problem = type_problem(cons[:type], value)
        return [at(path, problem)] if problem
      elsif (cons.key?(:properties) || cons.key?(:required)) && !value.is_a?(Hash)
        # Dial-level :json only; nested schemas carry an explicit type.
        return [at(path, "must be a JSON object (its schema declares properties)")]
      end

      out = []
      out << at(path, "must be one of #{cons[:enum].inspect}") if cons.key?(:enum) && !cons[:enum].include?(value)
      out << at(path, "must be >= #{cons[:minimum]}") if cons.key?(:minimum) && value < cons[:minimum]
      out << at(path, "must be <= #{cons[:maximum]}") if cons.key?(:maximum) && value > cons[:maximum]
      if cons.key?(:exclusive_minimum) && value <= cons[:exclusive_minimum]
        out << at(path, "must be > #{cons[:exclusive_minimum]}")
      end
      if cons.key?(:exclusive_maximum) && value >= cons[:exclusive_maximum]
        out << at(path, "must be < #{cons[:exclusive_maximum]}")
      end
      if cons.key?(:multiple_of) && !(value % cons[:multiple_of]).zero?
        out << at(path, "must be a multiple of #{cons[:multiple_of]}")
      end
      if cons.key?(:min_length) && value.length < cons[:min_length]
        out << at(path, "must be at least #{cons[:min_length]} characters")
      end
      if cons.key?(:max_length) && value.length > cons[:max_length]
        out << at(path, "must be at most #{cons[:max_length]} characters")
      end
      out << at(path, "must match #{cons[:pattern].inspect}") if cons.key?(:pattern) && !cons[:pattern].match?(value)

      out.concat(object_problems(cons, value, path)) if value.is_a?(Hash)
      if cons[:items] && value.is_a?(Array)
        value.each_with_index { |element, i| out.concat(problems(cons[:items], element, "#{path}[#{i}]")) }
      end
      out
    end

    def object_problems(cons, value, path)
      out = (cons[:required] || []).filter_map do |name|
        at(path, "is missing required key #{name.inspect}") unless value.key?(name)
      end
      (cons[:properties] || {}).each do |name, sub|
        out.concat(problems(sub, value[name], join(path, name))) if value.key?(name)
      end
      out
    end

    def type_problem(type, value)
      message, check = TYPE_CHECKS.fetch(type)
      message unless check.call(value)
    end

    def at(path, message)
      path ? "#{path} #{message}" : message
    end

    # -- serialization --------------------------------------------------------

    def render(cons)
      cons.each_with_object({}) do |(keyword, spec), out|
        case keyword
        when :type then out["type"] = spec.to_s
        when :pattern then out["pattern"] = spec.source
        when :properties then out["properties"] = spec.transform_values { |sub| render(sub) }
        when :items then out["items"] = render(spec)
        else out[CAMEL.fetch(keyword, keyword.to_s)] = spec
        end
      end
    end
  end
end

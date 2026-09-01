# frozen_string_literal: true

require "json"
require "literal"

module Dials
  # One declared dial: what it is, and everything you can do with it. Declared
  # once, in code, and frozen — the database stores values, never what a dial
  # *is*.
  #
  # Application code does not normally hold one of these. `Dials.checkout_fee_bps`
  # returns the *value*; you reach the object deliberately, through
  # `Dials[:checkout_fee_bps]`, when you want the declaration itself — an admin
  # screen rendering the catalog, or a console poking at the history.
  class Dial
    attr_reader :key, :default, :type, :variants, :label, :unit, :description

    # type::     anything that answers `===` — a class (`Integer`), a range,
    #            a regexp, a Literal type (`_Integer(1..10_000)`, `_Boolean`,
    #            `_JSONData`), a lambda. An Array is sugar for "one of these".
    # variants:: the dimensions this dial can vary along, each with the same
    #            kind of matcher: `{ market: %w[KE NG BD] }`. Declaring none
    #            makes the dial global-only by construction.
    def initialize(key, default:, type:, variants: {}, label: nil, unit: nil, description: nil)
      @key = key.to_sym
      @type = matcher(type)
      @variants = variants.to_h { |name, values| [name.to_sym, matcher(values)] }.freeze
      @label = label || @key.to_s.tr("_", " ").capitalize
      @unit = unit
      @description = description
      @default = cast(default)
      freeze
    rescue Error => e
      raise InvalidDial, "dial #{key}: #{e.message.delete_prefix("#{key}: ")}"
    end

    def variants? = !variants.empty?

    # Resolve the dial for a scope.
    #
    # Every stored scope the request satisfies is a candidate; the most
    # specific one wins, and the code default is what you get when none match.
    # The global override is not a special case — it is simply the candidate
    # that names no dimensions, so it matches every request and loses to
    # anything more specific.
    def for(**scope)
      requested = check_scope!(scope)

      # Checked after the scope, so a stub can never mask a read that would
      # have raised in production.
      stubs = Dials.stubs
      return stubs[key] if stubs&.key?(key)

      stored = Dials.overrides[key]
      return default if stored.nil?

      match = best_match(stored, requested)
      match.nil? ? default : match.last
    end

    # The global value, for dials that do not vary.
    def value = self.for

    # Turn the dial. With no scope this moves the global value; with one it
    # moves the value for exactly those dimensions. `actor:` is required and
    # lands in the change log.
    def adjust(value, actor:, **scope)
      stored = cast(value)
      Dials.append(key, Scope.dump(check_scope!(scope)), stored, actor)
      stored
    end

    # Drop an override, returning resolution to the layer below: a reset
    # variant falls back to the global, a reset global to the code default.
    # Returns false — and writes nothing — when there was nothing to reset.
    def reset(actor:, **scope)
      requested = check_scope!(scope)
      return false unless Dials.overrides[key]&.key?(requested)

      Dials.append(key, Scope.dump(requested), nil, actor)
      true
    end

    # Every stored override for this dial: { scope(Hash) => value }.
    def overrides = Dials.overrides.fetch(key, {})

    # This dial's change log, newest first — every adjustment and reset ever
    # made, with the actor who made it.
    def history(limit: 50) = Record.where(key: key.to_s).order(id: :desc).limit(limit)

    # Validate a candidate value and return it in the form it would be stored
    # and read back as. Public because an admin form wants to ask "would this
    # be accepted?" without writing anything.
    def cast(value)
      raise InvalidValue, "#{key}: value cannot be nil (reset the dial instead)" if value.nil?

      Literal.check(value, type)

      # Values make a round trip through JSON on the way to and from the
      # database. A value that does not survive one intact — a symbol key, a
      # Time, an Infinity — would be written as one thing and read back as
      # another, so it fails here rather than lying later.
      round_tripped = JSON.parse(JSON.generate(value), freeze: true)
      return round_tripped if round_tripped == value

      raise InvalidValue, "#{key}: #{value.inspect} does not survive a JSON round trip (use string keys and JSON-native types)"
    rescue Literal::TypeError => e
      raise InvalidValue, "#{key}: #{value.inspect} is not a valid value — #{e.message.strip.lines.first.strip.downcase}"
    rescue JSON::GeneratorError, SystemStackError
      raise InvalidValue, "#{key}: #{value.inspect} is not JSON-serializable"
    end

    def inspect
      parts = ["#<Dials::Dial #{key}", "default=#{default.inspect}", "type=#{type.inspect}"]
      parts << "variants=#{variants.keys.inspect}" if variants?
      "#{parts.join(' ')}>"
    end

    private

    # Anything that answers `===` is a matcher. An Array is sugar for an enum,
    # which is far and away the common case for a variant dimension.
    def matcher(spec)
      if spec.is_a?(Symbol)
        raise InvalidValue, "#{key}: #{spec.inspect} is not a type — pass a class (Integer), a Literal type (_Integer(1..10)), or an Array of allowed values"
      end

      spec.is_a?(Array) ? Set.new(spec) : spec
    end

    def check_scope!(scope)
      requested = Scope.normalize(scope)
      return requested if requested.empty?
      raise InvalidScope, "#{key} declares no variants, so it takes no scope" unless variants?

      requested.each do |name, value|
        allowed = variants[name]
        raise InvalidScope, "#{key} has no #{name} variant (it varies by: #{variants.keys.join(', ')})" if allowed.nil?
        raise InvalidScope, "#{value.inspect} is not a valid #{name} for #{key}" unless allowed === value
      end

      requested
    end

    # More dimensions wins; among equals, earlier-declared dimensions outrank
    # later ones. A stored scope matches when every pair it names is in the
    # request, so a partial scope ({market: "KE"}) covers every platform.
    def best_match(stored, requested)
      order = variants.keys
      stored
        .select { |scope, _| scope.all? { |name, value| requested[name] == value } }
        .min_by { |scope, _| [-scope.size, scope.keys.map { order.index(_1) }.sort] }
    end
  end
end

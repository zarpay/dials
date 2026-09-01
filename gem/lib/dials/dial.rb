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
    # A dimension cannot be named after a keyword the write methods already
    # take: it would be unreachable, and silently so — the write would target
    # the global instead of raising.
    RESERVED_DIMENSIONS = %i[actor if_unchanged_since].freeze

    # Keys land in an indexed column. Held well under it so that the
    # (key, scope, id) index stays inside every database's index budget —
    # (100 + 255) * 4 bytes on MySQL utf8mb4 is comfortably under InnoDB's cap.
    MAX_KEY_LENGTH = 100

    attr_reader :key, :default, :type, :dimensions, :label, :unit, :description

    # type::     anything that answers `===` — a class (`Integer`), a range,
    #            a regexp, a Literal type (`_Integer(1..10_000)`, `_Boolean`,
    #            `_JSONData`), a lambda. An Array is sugar for "one of these".
    # dimensions:: the dimensions this dial can vary along, each with the same
    #            kind of matcher: `{ market: %w[KE NG BD] }`. Declaring none
    #            makes the dial global-only by construction.
    def initialize(key, default:, type:, dimensions: {}, label: nil, unit: nil, description: nil)
      @key = key.to_sym
      @type = matcher(type)
      @dimensions = dimensions.to_h { |name, values| [name.to_sym, matcher(values)] }.freeze
      # Declaration order as a lookup. best_match runs on every read of an
      # overridden dial, and this never changes after the object is frozen.
      @dimension_rank = @dimensions.keys.each_with_index.to_h.freeze
      @label = label || @key.to_s.tr("_", " ").capitalize
      @unit = unit
      @description = description
      @default = cast(default)
      validate_declaration!
      freeze
    rescue Error => e
      raise InvalidDial, "dial #{key}: #{e.message.delete_prefix("#{key}: ")}"
    end

    def dimensions? = !dimensions.empty?

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

    # Turn the dial. With no scope this moves the global value; with one it
    # moves the value for exactly those dimensions. The actor lands in the
    # change log.
    #
    # `if_unchanged_since:` takes a token from #version and refuses the write
    # if the override moved in between — see #version for what that guarantee
    # is and is not.
    def adjust(value, actor: nil, if_unchanged_since: nil, **scope)
      requested = check_scope!(scope)
      stored = cast(value)
      assert_unchanged!(requested, if_unchanged_since)
      Dials.append(key, Scope.dump(requested), stored, actor)
      stored
    end

    # Drop an override, returning resolution to the layer below: a reset scoped
    # override falls back to the global, a reset global to the code default.
    # Returns false — and writes nothing — when there was nothing to reset.
    def reset(actor: nil, if_unchanged_since: nil, **scope)
      requested = check_scope!(scope)
      assert_unchanged!(requested, if_unchanged_since)
      return false unless Dials.overrides[key]&.key?(requested)

      Dials.append(key, Scope.dump(requested), nil, actor)
      true
    end

    # Every stored override for this dial: { scope(Hash) => value }.
    def overrides = Dials.overrides.fetch(key) { {} }

    # An opaque, monotonic stamp for one override — the id of the row that last
    # wrote it, or 0 when nothing is stored. Render it into a form alongside
    # the value, echo it back as `if_unchanged_since:`, and a write that would
    # clobber someone else's is refused instead.
    #
    # Read live rather than from the cache: a token taken from a snapshot up to
    # `cache_ttl` old would compare the caller against a past they never saw.
    # Ids only ever grow, so a cleared-and-reset override cannot revisit an old
    # token.
    def version(**scope) = stored_version(check_scope!(scope))

    # This dial's change log, newest first — every adjustment and reset ever
    # made, with the actor who made it.
    def history(limit: 50) = Record.history(key: key, limit: limit)

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
      parts << "dimensions=#{dimensions.keys.inspect}" if dimensions?
      "#{parts.join(' ')}>"
    end

    private

    # Advisory, and deliberately so. The check and the insert are NOT atomic —
    # an append-only table has no row to guard, which is the same property that
    # makes ordinary writes unable to conflict at all. A writer that squeezes
    # into the microseconds between them is not caught; the conflict this
    # exists to catch is two operators with the same form open, which takes
    # minutes to form. A guard rail, not a lock.
    def assert_unchanged!(scope, expected)
      return if expected.nil?

      current = stored_version(scope)
      return if current == expected

      raise StaleWrite, "#{key} changed since you read it (you saw #{expected}, it is now #{current})"
    end

    def stored_version(normalized_scope) = Record.version_for(key, Scope.dump(normalized_scope))

    def validate_declaration!
      if key.length > MAX_KEY_LENGTH
        raise InvalidValue, "#{key}: key is longer than #{MAX_KEY_LENGTH} characters"
      end

      reserved = dimensions.keys & RESERVED_DIMENSIONS
      return if reserved.empty?

      raise InvalidValue, "#{key}: #{reserved.join(', ')} cannot be a dimension name (the write methods already take it)"
    end

    # Anything that answers `===` is a matcher. An Array is sugar for an enum,
    # which is far and away the common case for a dimension.
    def matcher(spec)
      if spec.is_a?(Symbol)
        raise InvalidValue, "#{key}: #{spec.inspect} is not a type — pass a class (Integer), a Literal type (_Integer(1..10)), or an Array of allowed values"
      end

      spec.is_a?(Array) ? Set.new(spec) : spec
    end

    def check_scope!(scope)
      requested = Scope.normalize(scope)
      return requested if requested.empty?
      raise InvalidScope, "#{key} declares no dimensions, so it takes no scope" unless dimensions?

      requested.each do |name, value|
        allowed = dimensions[name]
        raise InvalidScope, "#{key} has no #{name} dimension (it varies by: #{dimensions.keys.join(', ')})" if allowed.nil?
        raise InvalidScope, "#{value.inspect} is not a valid #{name} for #{key}" unless allowed === value
      end

      requested
    end

    # More dimensions wins; among equals, earlier-declared dimensions outrank
    # later ones. A stored scope matches when every pair it names is in the
    # request, so a partial scope ({market: "KE"}) covers every platform.
    def best_match(stored, requested)
      stored
        .select { |scope, _| scope.all? { |name, value| requested[name] == value } }
        .min_by { |scope, _| [-scope.size, scope.keys.map { @dimension_rank[_1] }.sort] }
    end
  end
end

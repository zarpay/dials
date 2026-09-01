# frozen_string_literal: true

require "json"
require "literal"

require_relative "dials/version"

# Dials: constants you can turn without a deploy.
#
# A dial is declared in code with a default, a type, and optionally the
# dimensions it may vary along. Operators override it at runtime; the override
# lives in one append-only table, is served from a per-process cache, and
# carries the actor who made it.
#
#   Dials.define do
#     dial :checkout_fee_bps, default: 250, type: _Integer(1..10_000),
#          unit: "bps", dimensions: { market: %w[KE NG BD] }
#   end
#
#   Dials.checkout_fee_bps                   # => 250
#   Dials.checkout_fee_bps(market: "KE")     # => 250
#   Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: ops)
#   Dials.checkout_fee_bps(market: "BD")     # => 120
#
# Declaring a dial generates one method, and it returns the value — never an
# object wrapping it. That is deliberate: an object standing in for a boolean
# is truthy even when the boolean is false, so a kill switch you had turned
# off would read as on. The declaration itself is reachable, but only by
# asking for it: Dials[:checkout_fee_bps].
module Dials
  class Error < StandardError; end

  # Asked for a dial that was never declared.
  class UnknownDial < Error; end

  # The declaration itself is wrong (bad type, default that fails its own type,
  # a key that is already taken).
  class InvalidDial < Error; end

  # A value that a dial will not accept.
  class InvalidValue < Error; end

  # A scope that names a dimension the dial does not have, or a value that
  # dimension does not allow.
  class InvalidScope < Error; end

  # A write carrying `if_unchanged_since:` whose override moved in between.
  class StaleWrite < Error; end
end

require_relative "dials/scope"
require_relative "dials/dial"
require_relative "dials/record"

module Dials
  # Per-dial reader methods (`Dials.checkout_fee_bps`) are defined here rather
  # than on Dials itself, so `undefine_all!` can strip every one of them without
  # going anywhere near the real API.
  module Readers; end
  extend Readers

  # The DSL `Dials.define` runs its block against. It includes Literal's type
  # helpers, so `_Integer(1..10_000)` and friends are in scope inside the block
  # without the app having to include anything.
  class DSL
    include Literal::Types

    def dial(key, **) = Dials.register(Dial.new(key, **))
  end

  # Thread-local pinned values (see .stub).
  STUBS = :dials_stubs

  # How an actor is labelled in the change log, when the app has not said
  # otherwise.
  DEFAULT_ACTOR_LABEL = lambda do |actor|
    if actor.is_a?(String) then actor
    elsif actor.respond_to?(:email) && actor.email then actor.email
    elsif actor.respond_to?(:name) && actor.name then actor.name
    else [actor.class.name, (actor.id if actor.respond_to?(:id))].compact.join("#")
    end
  end

  class << self
    # Seconds between checks for writes made by *other* processes. 0 (or nil)
    # checks on every read; the default trades five seconds of convergence for
    # one query per five seconds per process. There is no "never check" setting
    # — a cache that can never notice another process is a cache that can be
    # wrong forever.
    attr_accessor :cache_ttl

    # A callable turning an actor into the label stored on every change.
    attr_accessor :actor_label

    # Who to attribute a write to when the caller passes no `actor:`. A string,
    # an object, or a callable evaluated per write — for apps with no user
    # identity behind a console or a rake task. An explicit `actor:` always
    # wins; with none declared, a write without one still raises.
    attr_accessor :default_actor

    def configure = yield(self)

    # -- declaring -----------------------------------------------------------

    # Declare dials. Call it as many times as you like; declarations
    # accumulate, so an app can split them up by domain.
    def define(&) = DSL.new.instance_eval(&)

    # The dial itself — its default, type, dimensions, overrides and history.
    # Deliberately explicit: application code reads values through the
    # generated methods and never needs one of these.
    def [](key)
      registry.fetch(key.to_sym) do
        raise UnknownDial, "no dial named #{key.inspect} (declared: #{registry.keys.join(', ')})"
      end
    end

    def registry = @registry ||= {}
    def all = registry.values
    def each(&) = all.each(&)

    # Every declared dial paired with its stored overrides, read from ONE
    # snapshot — so an admin index cannot render one dial from before a write
    # and the next from after. => [[Dial, { scope => value }], ...]
    def catalog
      snapshot = overrides
      all.map { |dial| [dial, snapshot.fetch(dial.key) { {} }] }
    end

    # Not public API; DSL#dial calls it.
    def register(dial)
      raise InvalidDial, "dial #{dial.key} is already declared" if registry.key?(dial.key)
      raise InvalidDial, "dial #{dial.key} would define Dials.#{dial.key}, which already exists" if respond_to?(dial.key, true)

      # The generated method resolves and returns the value. Nothing in the
      # ergonomic path ever hands out the Dial.
      Readers.define_method(dial.key) { |**scope| dial.for(**scope) }
      registry[dial.key] = dial
    end

    # -- reading -------------------------------------------------------------

    # Every stored override in the system, cached per process:
    #
    #   { key(Symbol) => { scope(Hash) => value } }
    #
    # Rebuilt immediately when this process writes, and — at most once every
    # `cache_ttl` seconds — when a cheap version check shows that another
    # process has.
    def overrides
      cached = @overrides
      return cached if cached && !probe_due?

      @probed_at = monotonic
      version = Record.version
      return cached if cached && version == @version

      # Version read before the data: if a write lands between the two, the
      # cache carries a version older than what it holds and the next probe
      # rebuilds. Stale only ever in the safe direction. Both fields are
      # assigned only once the load has succeeded, so a failed rebuild cannot
      # leave the version claiming to be current.
      loaded = Record.overrides
      @version = version
      @overrides = loaded
    rescue ::ActiveRecord::ActiveRecordError => e
      # A database blip must not take down every dial read in the process —
      # including on paths that would not otherwise touch the database. With a
      # snapshot in hand, serve it and say so; with none there is nothing
      # honest to serve. The probe timestamp was claimed above, so a downed
      # database is retried once per cache_ttl rather than on every read.
      raise unless cached

      warn "[dials] serving the last known overrides (#{e.class}: #{e.message})"
      cached
    end

    # Force the next read to rebuild from the database. Test suites that roll
    # each example back should call this between examples.
    def reload!
      @overrides = nil
      @probed_at = nil
      @version = nil
    end

    # The whole change log, newest first.
    def history(limit: 50) = Record.history(limit: limit)

    # -- writing -------------------------------------------------------------

    # Turn a dial. With no scope this moves the global value; with one it moves
    # the value for exactly those dimensions. The actor lands in the change log,
    # and is required unless the app declares a `default_actor`.
    #
    #   Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: current_admin)
    #
    # Writes name the key rather than going through a generated method, because
    # the surfaces that write — an admin form, a console, a circuit breaker —
    # are holding a key already, and because a write is worth spelling out.
    def adjust(key, value, actor: nil, if_unchanged_since: nil, **scope)
      self[key].adjust(value, actor: actor, if_unchanged_since: if_unchanged_since, **scope)
    end

    # Drop an override, returning resolution to the layer below: a reset scoped
    # override falls back to the global, a reset global to the code default. Returns
    # false — and writes nothing — when there was nothing to reset.
    def reset(key, actor: nil, if_unchanged_since: nil, **scope)
      self[key].reset(actor: actor, if_unchanged_since: if_unchanged_since, **scope)
    end

    # Not public API; Dial#adjust and Dial#reset call it.
    def append(key, scope, value, actor)
      actor = default_actor.respond_to?(:call) ? default_actor.call : default_actor if actor.nil?
      raise Error, "every write needs an actor: (who is turning this dial?)" if actor.nil?

      Record.create!(
        key: key.to_s,
        scope: scope,
        value: Record.encode(value),
        actor_type: (actor.class.name unless actor.is_a?(String)),
        actor_id: (actor.id.to_s if actor.respond_to?(:id)),
        actor_label: (actor_label || DEFAULT_ACTOR_LABEL).call(actor).to_s
      )

      # This process reads its own write immediately. If the write is inside an
      # application transaction that has not committed yet, reload again once
      # it settles, so the cache reflects the outcome and not the attempt.
      reload!
      ::ActiveRecord.after_all_transactions_commit { reload! }
    end

    # -- testing -------------------------------------------------------------

    # Pin dial values for the duration of a block, on this thread only — no
    # database, no cache, no history:
    #
    #   Dials.stub(checkout_fee_bps: 999) { ... }
    #
    # Values are validated, so a test cannot pin something production could
    # never hold.
    def stub(values)
      pinned = values.to_h do |key, value|
        dial = self[key]
        [dial.key, dial.cast(value)]
      end

      previous = Thread.current[STUBS]
      Thread.current[STUBS] = (previous || {}).merge(pinned)
      yield
    ensure
      Thread.current[STUBS] = previous
    end

    def stubs = Thread.current[STUBS]

    # Test hook: forget every declaration and its generated reader.
    def undefine_all!
      Readers.instance_methods(false).each { |name| Readers.send(:remove_method, name) }
      registry.clear
      reload!
    end

    private

    def probe_due?
      return true if cache_ttl.to_f <= 0

      @probed_at.nil? || (monotonic - @probed_at) >= cache_ttl
    end

    def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  self.cache_ttl = 5.0
end

# frozen_string_literal: true

module Dials
  # Per-dial generated methods. Declaring `dial :base_fee, ...` defines
  #
  #   Dials.base_fee(**scope)                       # read  (Dials.get)
  #   Dials.adjust_base_fee(value, actor:, **scope) # write (Dials.set)
  #   Dials.clear_base_fee(actor:, **scope)         # clear (Dials.clear)
  #
  # The reader is the bare dial name — reading is what you do with a dial
  # all day, so it pays no prefix tax; the writers carry their verbs. These
  # are real methods defined at declaration time — never method_missing — so
  # respond_to?, tab completion, and a grep for `base_fee` all work. A dial
  # whose name collides with an existing Dials method (:store, :cache,
  # :changes, ...) fails at boot rather than shadowing the API.
  #
  # Scope travels as bare keywords here (`market: "KE"`), which is why
  # `actor` and `expected_version` are reserved dimension names: on
  # adjust_/clear_ they must always mean attribution and stale-write
  # protection, never scope. Definition enforces the reservation.
  #
  # The methods live on this module (which Dials extends) rather than on
  # Dials directly so Registry#reset! can strip every generated method
  # without touching the core API.
  module Generated
    class << self
      # Define the three methods for a definition. Collisions are checked
      # first — all three names, including against private methods, since a
      # method on Dials itself would shadow anything defined here — so a
      # raise leaves nothing half-installed.
      def install!(definition)
        key = definition.key
        names = [key, :"adjust_#{key}", :"clear_#{key}"]

        names.each do |name|
          next unless Dials.respond_to?(name, true)

          raise InvalidDefinition, "dial #{key} would define Dials.#{name}, which already exists"
        end

        # actor: defaults to nil rather than being a required keyword so that
        # apps declaring config.default_actor can write without one; with no
        # default configured, Actor.normalize still raises MissingActor.
        define_method(names[0]) { |**scope| get(key, **scope) }
        define_method(names[1]) do |value, actor: nil, expected_version: nil, **scope|
          set(key, value, actor: actor, scope: scope, expected_version: expected_version)
        end
        define_method(names[2]) do |actor: nil, expected_version: nil, **scope|
          clear(key, actor: actor, scope: scope, expected_version: expected_version)
        end
      end

      def uninstall_all!
        instance_methods(false).each { |name| remove_method(name) }
      end
    end
  end

  extend Generated
end

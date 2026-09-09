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
  # whose name collides with an existing method on its namespace (:store,
  # :cache, :changes, ...) fails at boot rather than shadowing the API.
  #
  # Scope travels as bare keywords here (`market: "KE"`), which is why
  # `actor` and `expected_version` are reserved dimension names: on
  # adjust_/clear_ they must always mean attribution and stale-write
  # protection, never scope. Definition enforces the reservation.
  #
  # The methods live in a module the namespace extends (never on the
  # namespace directly) so Registry#reset! can strip every generated method
  # without touching the core API. Each namespace owns its own module, so
  # two namespaces can declare the same key.
  module Generated
    class << self
      # Define the three methods for a definition in `into`, a module the
      # namespace extends. Collisions are checked first — all three names
      # against every owner, including private methods, since a method on
      # the owner itself would shadow anything defined here — so a raise
      # leaves nothing half-installed. `owners` maps the name a user would
      # type ("Dials") to the object that answers it.
      def install!(definition, into:, owners:)
        key = definition.key
        names = [key, :"adjust_#{key}", :"clear_#{key}"]

        names.each do |name|
          owners.each do |label, owner|
            next unless owner.respond_to?(name, true)

            raise InvalidDefinition, "dial #{key} would define #{label}.#{name}, which already exists"
          end
        end

        # actor: defaults to nil rather than being a required keyword so that
        # apps declaring config.default_actor can write without one; with no
        # default configured, Actor.normalize still raises MissingActor.
        into.define_method(names[0]) { |**scope| get(key, **scope) }
        into.define_method(names[1]) do |value, actor: nil, expected_version: nil, **scope|
          set(key, value, actor: actor, scope: scope, expected_version: expected_version)
        end
        into.define_method(names[2]) do |actor: nil, expected_version: nil, **scope|
          clear(key, actor: actor, scope: scope, expected_version: expected_version)
        end
      end

      def uninstall_all!(from:)
        from.instance_methods(false).each { |name| from.remove_method(name) }
      end
    end
  end
end

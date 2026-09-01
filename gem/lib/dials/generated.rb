# frozen_string_literal: true

module Dials
  # Per-dial generated methods. Declaring `dial :base_fee, ...` defines
  #
  #   Dials.use_base_fee(**scope)                   # read  (Dials.get)
  #   Dials.adjust_base_fee(value, actor:, **scope) # write (Dials.set)
  #   Dials.clear_base_fee(actor:, **scope)         # clear (Dials.clear)
  #
  # These are real methods defined at declaration time — never
  # method_missing — so respond_to?, tab completion, and a grep for
  # `use_base_fee` all work.
  #
  # Scope travels as bare keywords here (`market: "KE"`), which is why
  # `actor` is a reserved dimension name: on adjust_/clear_ it must always
  # mean attribution, never scope. Definition enforces the reservation.
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
        names = [:"use_#{key}", :"adjust_#{key}", :"clear_#{key}"]

        names.each do |name|
          next unless Dials.respond_to?(name, true)

          raise InvalidDefinition, "dial #{key} would define Dials.#{name}, which already exists"
        end

        define_method(names[0]) { |**scope| get(key, **scope) }
        define_method(names[1]) { |value, actor:, **scope| set(key, value, actor: actor, scope: scope) }
        define_method(names[2]) { |actor:, **scope| clear(key, actor: actor, scope: scope) }
      end

      def uninstall_all!
        instance_methods(false).each { |name| remove_method(name) }
      end
    end
  end

  extend Generated
end

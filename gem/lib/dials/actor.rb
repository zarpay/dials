# frozen_string_literal: true

module Dials
  # Normalizes whatever the caller passes as `actor:` into the three strings
  # the change log stores. An ActiveRecord-ish object contributes its class
  # name and id; a plain string is stored as the label; anything else uses
  # its class and to_s. The label can be customized app-wide via
  # `Dials.configure { |c| c.actor_label = ->(actor) { actor.email } }`.
  #
  # A nil actor falls back to `config.default_actor` (for apps without user
  # identity); when that is also nil/absent, MissingActor — there is no
  # anonymous mutation path the app didn't explicitly declare.
  module Actor
    module_function

    def normalize(actor)
      actor = default_actor if actor.nil?
      if actor.nil?
        raise MissingActor, "every write requires an actor: (who is making this change?) — " \
                            "pass actor:, or set config.default_actor for apps without user identity"
      end

      {
        actor_type: actor_type(actor),
        actor_id: actor_id(actor),
        actor_label: Dials.config.actor_label.call(actor).to_s
      }
    end

    # The configured fallback; a callable is evaluated per write (so
    # `-> { ENV.fetch("USER", "console") }` names whoever runs the console).
    def default_actor
      configured = Dials.config.default_actor
      configured.respond_to?(:call) ? configured.call : configured
    end

    def actor_type(actor)
      actor.is_a?(String) ? nil : actor.class.name
    end

    def actor_id(actor)
      actor.respond_to?(:id) ? actor.id.to_s : nil
    end

    DEFAULT_LABEL = lambda do |actor|
      if actor.is_a?(String)
        actor
      elsif actor.respond_to?(:email) && actor.email
        actor.email
      elsif actor.respond_to?(:name) && actor.name
        actor.name
      else
        [actor.class.name, actor.respond_to?(:id) ? actor.id : nil].compact.join("#")
      end
    end
  end
end

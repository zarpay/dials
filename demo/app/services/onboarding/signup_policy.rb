# frozen_string_literal: true

module Onboarding
  # The kill-switch consumer. `signups_enabled` is deliberately global-only
  # (no dimensions: declared) — when signups must stop, they stop everywhere,
  # with one flip. The dial cannot be given a per-market value even by a
  # determined operator; the gem rejects any scoped write for it.
  class SignupPolicy
    def self.allowed?
      Dials.use_signups_enabled
    end
  end
end

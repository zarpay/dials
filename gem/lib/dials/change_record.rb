# frozen_string_literal: true

module Dials
  # One entry in the change log, in a store-independent shape. `scope` is nil
  # for global changes; `old_value` is nil when no override existed before
  # (the write introduced the override); `new_value` is nil for clears.
  #
  # The change log is append-only and doubles as the store's version counter,
  # so every mutation the public API performs lands here by construction.
  ChangeRecord = Data.define(:key, :scope, :action, :old_value, :new_value,
                             :actor_type, :actor_id, :actor_label, :created_at) do
    def global?
      scope.nil?
    end
  end
end

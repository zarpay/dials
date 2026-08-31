# frozen_string_literal: true

require "active_record"
require "dials"

# The adapter's cache-coherence contract for writes inside application
# transactions depends on ActiveRecord.after_all_transactions_commit
# (added in 7.2). On older ActiveRecord there is no safe commit-time bust:
# a mid-transaction republish of pre-commit state could outlive the commit
# indefinitely. Failing loudly here beats shipping that silent gap.
if Gem::Version.new(ActiveRecord::VERSION::STRING) < Gem::Version.new("7.2")
  raise Dials::Error,
        "dials/active_record requires ActiveRecord >= 7.2 " \
        "(found #{ActiveRecord::VERSION::STRING}); the :memory store works on any version"
end

require_relative "active_record/models"
require_relative "active_record/store"

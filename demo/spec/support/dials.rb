# frozen_string_literal: true

# Dials + transactional specs: each example's writes roll back with the
# transaction, but the per-process CACHE would happily keep serving them —
# so every example starts by discarding the cached snapshot. This is the one
# line a client app needs for dial hygiene in its test suite.
RSpec.configure do |config|
  config.before { Dials.reload! }
end

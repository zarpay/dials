# frozen_string_literal: true

# Dials + transactional specs: each example's writes roll back with the
# transaction, but the per-process CACHE would happily keep serving them —
# so every example starts by discarding the cached snapshot. This is the one
# line a client app needs for dial hygiene in its test suite.
#
# reload_all! covers every namespace (see config/initializers/dials_courier.rb);
# an app with no namespaces gets the same result from Dials.reload!.
RSpec.configure do |config|
  config.before { Dials.reload_all! }
end

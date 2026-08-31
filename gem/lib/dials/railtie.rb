# frozen_string_literal: true

module Dials
  # Present so future Rails integration points (rake tasks, reload hooks)
  # have a home. Generators under lib/generators are discovered by Rails on
  # their own; requiring the gem inside a Rails app is enough for
  # `bin/rails generate dials:install` to work.
  class Railtie < Rails::Railtie
  end
end

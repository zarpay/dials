# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Dials
  module Generators
    # bin/rails generate dials:install
    class InstallGenerator < Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/create_dials.rb"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/dials.rb"
      end
    end
  end
end

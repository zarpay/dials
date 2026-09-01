# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Dials
  module Generators
    # `bin/rails generate dials:install`
    #
    # Creates the migration for the three gem-owned tables and an initializer
    # with a commented starter registry.
    class InstallGenerator < Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/create_dials_tables.rb"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/dials.rb"
      end

      def show_readme
        say <<~TEXT

          Dials installed. Next steps:

            1. bin/rails db:migrate
            2. Declare your dials in config/initializers/dials.rb
            3. Declaring dial :base_fee generates Dials.use_base_fee,
               Dials.adjust_base_fee, and Dials.clear_base_fee

        TEXT
      end
    end
  end
end

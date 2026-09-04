# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Dials
  module Generators
    # `bin/rails generate dials:install`
    #
    # Creates the migration for the gem-owned table and an initializer with
    # a commented starter registry. --table-name-prefix prefixes the table
    # (Rails table_name_prefix convention, trailing underscore included) for
    # apps where "dials" collides with an existing one.
    class InstallGenerator < Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :table_name_prefix, type: :string, default: "",
                   desc: 'Prefix for the gem-owned table, used verbatim ("zar_" creates zar_dials)'

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/create_#{table_name}_table.rb"
      end

      def create_initializer
        template "initializer.rb.tt", "config/initializers/dials.rb"
      end

      def show_readme
        say <<~TEXT

          Dials installed. Next steps:

            1. bin/rails db:migrate
            2. Declare your dials in config/initializers/dials.rb
            3. Declaring dial :base_fee generates Dials.base_fee,
               Dials.adjust_base_fee, and Dials.clear_base_fee

        TEXT
      end

      private

      def table_name
        "#{options[:table_name_prefix]}dials"
      end
    end
  end
end

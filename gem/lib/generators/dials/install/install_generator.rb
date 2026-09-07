# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"
require "dials"

module Dials
  module Generators
    # `bin/rails generate dials:install`
    #
    # Creates the migration for a dials table and an initializer with a
    # commented starter registry.
    class InstallGenerator < Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      class_option :table_name_prefix, type: :string, default: "",
                   desc: 'Prefix for the default namespace\'s table, used verbatim ("zar_" creates zar_dials)'
      class_option :namespace, type: :string, default: "",
                   desc: "Install a namespace of this name instead of the default one (creates <name>_dials)"

      def verify_options
        return if namespace_name.empty?

        unless options[:table_name_prefix].empty?
          raise Thor::Error,
                "--table-name-prefix names the default namespace's table; a namespace's table is " \
                "<name>_dials (rename it with config.table_name in the initializer)"
        end

        # The name becomes a table name, a constant, and a migration class
        # name — an invalid one writes files that do not parse.
        return if Dials::Namespace::NAME_FORMAT.match?(namespace_name)

        raise Thor::Error,
              "--namespace must be lowercase letters, digits and single underscores " \
              "(it becomes a table name)"
      end

      def create_migration_file
        migration_template "migration.rb.tt", "db/migrate/create_#{table_name}_table.rb"
      end

      def create_initializer
        if namespace_name.empty?
          template "initializer.rb.tt", "config/initializers/dials.rb"
        else
          template "namespace_initializer.rb.tt", "config/initializers/dials_#{namespace_name}.rb"
        end
      end

      def show_readme
        say <<~TEXT

          Dials installed. Next steps:

            1. bin/rails db:migrate
            2. Declare your dials in config/initializers/#{initializer_name}
            3. Declaring dial :base_fee generates #{facade}.base_fee,
               #{facade}.adjust_base_fee, and #{facade}.clear_base_fee

        TEXT
      end

      private

      def namespace_name
        options[:namespace].to_s
      end

      def table_name
        return "#{options[:table_name_prefix]}dials" if namespace_name.empty?

        "#{namespace_name}_dials"
      end

      def initializer_name
        namespace_name.empty? ? "dials.rb" : "dials_#{namespace_name}.rb"
      end

      # What a caller types to reach these dials.
      def facade
        namespace_name.empty? ? "Dials" : constant_name
      end

      def constant_name
        namespace_name.split("_").map(&:capitalize).join
      end

      def label
        namespace_name.split("_").map(&:capitalize).join(" ")
      end
    end
  end
end

# frozen_string_literal: true

require "test_helper"
require "rails/generators/test_case"
require "generators/dials/install/install_generator"

class InstallGeneratorTest < Rails::Generators::TestCase
  tests Dials::Generators::InstallGenerator
  destination File.expand_path("../tmp/generator", __dir__)
  setup :prepare_destination

  def test_installs_the_default_namespace
    run_generator

    assert_migration "db/migrate/create_dials_table.rb" do |migration|
      assert_match(/create_table :dials/, migration)
      assert_match(/class CreateDialsTable/, migration)
    end
    assert_file "config/initializers/dials.rb" do |initializer|
      assert_match(/Dials\.configure/, initializer)
      assert_match(/config\.store = :active_record/, initializer)
      assert_match(/Dials\.define do/, initializer)
    end
  end

  def test_table_name_prefix_names_the_table_and_the_initializer_matches
    run_generator ["--table-name-prefix=zar_"]

    assert_migration "db/migrate/create_zar_dials_table.rb" do |migration|
      assert_match(/create_table :zar_dials/, migration)
    end
    assert_file "config/initializers/dials.rb", /config\.table_name_prefix = "zar_"/
  end

  def test_namespace_installs_its_own_table_and_initializer
    run_generator ["--namespace=bank_transfer"]

    assert_migration "db/migrate/create_bank_transfer_dials_table.rb" do |migration|
      assert_match(/create_table :bank_transfer_dials/, migration)
      assert_match(/class CreateBankTransferDialsTable/, migration)
    end
    assert_no_file "config/initializers/dials.rb"
    assert_file "config/initializers/dials_bank_transfer.rb" do |initializer|
      assert_match(/BankTransfer = Dials\.namespace\(:bank_transfer, label: "Bank Transfer"\)/, initializer)
      assert_match(/config\.store = :active_record/, initializer)
      assert_match(/BankTransfer\.define do/, initializer)
    end
  end

  def test_a_namespace_name_that_is_not_a_table_name_is_refused
    assert_match(/lowercase/, generator_complaint(["--namespace=Bank-Transfer"]))
    assert_no_migration "db/migrate/create_Bank-Transfer_dials_table.rb"
  end

  def test_a_namespace_takes_no_table_name_prefix
    assert_match(/config\.table_name/, generator_complaint(["--namespace=transfers", "--table-name-prefix=zar_"]))
    assert_no_file "config/initializers/dials_transfers.rb"
    assert_no_migration "db/migrate/create_transfers_dials_table.rb"
  end

  private

  # Thor prints the error and stops; minitest's capture_io cannot be nested
  # inside the stdout capture run_generator already does.
  def generator_complaint(args)
    original = $stderr
    $stderr = StringIO.new
    begin
      run_generator args
      $stderr.string
    ensure
      $stderr = original
    end
  end
end

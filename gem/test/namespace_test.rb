# frozen_string_literal: true

require "test_helper"

class NamespaceTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    @shipping = Dials.namespace(:shipping, label: "Shipping") do |config|
      config.store = :memory
    end
    @payouts = Dials.namespace(:payouts) { |config| config.store = :memory }
  end

  # -- declaration and lookup --------------------------------------------------

  def test_namespaces_are_fetched_by_name
    assert_same @shipping, Dials.namespace(:shipping)
    assert_same @shipping, Dials.namespace("shipping")
  end

  def test_fetching_an_unknown_namespace_raises
    error = assert_raises(Dials::UnknownNamespace) { Dials.namespace(:nope) }
    assert_match(/shipping/, error.message)
  end

  def test_declaring_a_namespace_twice_raises
    assert_raises(Dials::DuplicateNamespace) { Dials.namespace(:shipping) { |c| c.store = :memory } }
    assert_raises(Dials::DuplicateNamespace) { Dials.namespace(:default, label: "Mine") }
  end

  def test_a_namespace_name_must_read_as_a_table_name
    # Anything else could derive a table or a model class another namespace
    # already owns: "flat_1" and "flat1" both camelize to Flat1Entry, so a
    # segment starting with a digit is refused.
    ["flat rate", "FlatRate", "flat__rate", "shipping_", "_shipping", "1st", "flat_1"].each do |name|
      assert_raises(Dials::InvalidNamespace, "#{name.inspect} must be refused") do
        Dials.namespace(name, label: "x")
      end
    end
  end

  def test_namespaces_lists_the_root_first_then_registration_order
    assert_equal %i[default shipping payouts], Dials.namespaces.map(&:name)
    assert_same Dials.default, Dials.namespaces.first
  end

  def test_labels_default_to_the_humanized_name_and_dials_for_the_root
    assert_equal "Shipping", @shipping.label
    assert_equal "Payouts", @payouts.label
    assert_equal "Dials", Dials.default.label

    Dials.configure { |c| c.label = "Bazario" }
    assert_equal "Bazario", Dials.default.label
  end

  # -- independence ------------------------------------------------------------

  def test_the_same_key_in_two_namespaces_resolves_independently
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }

    assert_equal 30, @shipping.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal 60, @shipping.timeout_seconds
    assert_equal 5, @payouts.timeout_seconds, "a write in one namespace never moves another's value"
  end

  def test_a_key_declared_in_a_namespace_is_unknown_to_the_root
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }

    assert_raises(Dials::UnknownDial) { Dials.get(:timeout_seconds) }
    refute_respond_to Dials, :timeout_seconds
    refute Dials.registry.defined?(:timeout_seconds)
  end

  def test_each_namespace_keeps_its_own_change_log
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    assert_equal 1, @shipping.changes.length
    assert_empty @payouts.changes
    assert_empty Dials.changes
  end

  def test_a_write_busts_only_its_own_cache
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }
    Dials.configure { |c| c.cache_ttl = nil } # only busts converge

    shipping_snapshot = @shipping.cache.snapshot
    payouts_snapshot = @payouts.cache.snapshot

    @shipping.adjust_timeout_seconds(60, actor: ACTOR)

    refute_same shipping_snapshot, @shipping.cache.snapshot
    assert_same payouts_snapshot, @payouts.cache.snapshot
  end

  def test_overview_covers_one_namespace_only
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :retries, default: 2, type: :integer }

    assert_equal %i[timeout_seconds], @shipping.overview.dials.map { |d| d.definition.key }
    assert_equal %i[retries], @payouts.overview.dials.map { |d| d.definition.key }
    assert_empty Dials.overview.dials
  end

  def test_with_overrides_pins_one_namespace_only
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }

    @shipping.with_overrides(timeout_seconds: 99) do
      assert_equal 99, @shipping.timeout_seconds
      assert_equal 5, @payouts.timeout_seconds
    end

    assert_equal 30, @shipping.timeout_seconds
  end

  def test_root_test_overrides_leave_a_namespace_alone
    Dials.define { dial :timeout_seconds, default: 30, type: :integer }
    @shipping.define { dial :timeout_seconds, default: 5, type: :integer }

    Dials::Testing.with_overrides(timeout_seconds: 99) do
      assert_equal 99, Dials.timeout_seconds
      assert_equal 5, @shipping.timeout_seconds
    end
  end

  # -- generated methods -------------------------------------------------------

  def test_generated_methods_land_on_the_namespace_not_on_dials
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }

    %i[timeout_seconds adjust_timeout_seconds clear_timeout_seconds].each do |name|
      assert_respond_to @shipping, name
      refute_respond_to Dials, name
      refute_respond_to @payouts, name
    end
  end

  def test_a_dial_cannot_shadow_the_namespace_api
    error = assert_raises(Dials::InvalidDefinition) do
      @shipping.define { dial :store, default: 1, type: :integer }
    end
    assert_match(/Dials.namespace\(:shipping\).store, which already exists/, error.message)
    refute @shipping.registry.defined?(:store)
  end

  def test_a_namespace_dial_may_take_a_name_the_root_module_uses
    @shipping.define { dial :namespaces, default: 1, type: :integer }

    assert_equal 1, @shipping.namespaces
  end

  def test_resetting_a_namespace_registry_strips_only_its_methods
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @payouts.define { dial :timeout_seconds, default: 5, type: :integer }

    @shipping.registry.reset!

    refute_respond_to @shipping, :timeout_seconds
    assert_equal 5, @payouts.timeout_seconds
  end

  # -- configuration -----------------------------------------------------------

  def test_unset_options_inherit_the_root_config
    Dials.configure do |c|
      c.cache_ttl = 42
      c.default_actor = "the app"
      c.actor_label = ->(actor) { "custom:#{actor}" }
    end

    assert_equal 42, @shipping.config.cache_ttl
    assert_equal "the app", @shipping.config.default_actor

    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    @shipping.adjust_timeout_seconds(60)

    assert_equal "custom:the app", @shipping.changes.first.actor_label
  end

  def test_a_namespace_option_overrides_the_inherited_one
    Dials.configure { |c| c.default_actor = "the app" }
    @shipping.configure { |c| c.default_actor = "the engine" }

    assert_equal "the app", Dials.config.default_actor
    assert_equal "the engine", @shipping.config.default_actor
  end

  def test_an_inherited_cache_ttl_reaches_a_live_namespace_cache
    @shipping.configure { |c| c.cache_ttl = 1 }
    assert_equal 1, @shipping.cache.ttl

    Dials.configure { |c| c.cache_ttl = 99 }

    assert_equal 99, @payouts.cache.ttl, "an inherited ttl follows the root"
    assert_equal 1, @shipping.cache.ttl, "a declared ttl is the namespace's own"
  end

  def test_a_store_object_is_never_inherited
    Dials.configure { |c| c.store = Dials::Stores::Memory.new }
    inheriting = Dials.namespace(:inheriting) { |_config| nil }

    error = assert_raises(Dials::Error) { inheriting.store }
    assert_match(/config.store/, error.message)
  end

  def test_each_namespace_gets_a_memory_store_of_its_own
    refute_same @shipping.store, @payouts.store
    refute_same @shipping.store, Dials.store
  end

  def test_a_store_swap_on_the_root_reaches_a_namespace_that_inherits_it
    inheriting = Dials.namespace(:inheriting) { |_config| nil }
    inherited = inheriting.store
    declared = @shipping.store

    Dials.configure { |c| c.store = :memory }

    refute_same inherited, inheriting.store, "an inherited store follows the root's kind"
    assert_same declared, @shipping.store, "a declared store is the namespace's own"
  end

  def test_the_default_table_name_is_derived_from_the_namespace_name
    assert_equal "shipping_dials", @shipping.config.table_name
    assert_equal "dials", Dials.config.table_name

    @shipping.configure { |c| c.table_name = "engine_settings" }
    assert_equal "engine_settings", @shipping.config.table_name
  end

  def test_a_table_name_must_read_as_a_plain_identifier
    # It reaches the model's table_name and the store's hand-built NOT
    # EXISTS subquery, neither of which quotes it.
    ["order table", "Orders", "public.dials", 'dials"; --', "d" * 64].each do |name|
      assert_raises(Dials::InvalidTableName, "#{name.inspect} must be refused") do
        @shipping.configure { |c| c.table_name = name }
      end
    end
  end

  def test_two_namespaces_cannot_claim_one_table
    error = assert_raises(Dials::InvalidTableName) do
      @payouts.configure { |c| c.table_name = "shipping_dials" }
    end
    assert_match(/shipping/, error.message)
  end

  def test_the_roots_prefix_cannot_claim_a_namespaces_table
    assert_raises(Dials::InvalidTableName) { Dials.configure { |c| c.table_name_prefix = "shipping_" } }
  end

  def test_table_name_prefix_is_the_roots_alone
    error = assert_raises(Dials::Error) { @shipping.configure { |c| c.table_name_prefix = "ops_" } }
    assert_match(/config.table_name/, error.message)
  end

  def test_reload_all_clears_every_cache
    @shipping.define { dial :timeout_seconds, default: 30, type: :integer }
    Dials.configure { |c| c.cache_ttl = nil }
    snapshot = @shipping.cache.snapshot

    Dials.reload_all!

    refute_same snapshot, @shipping.cache.snapshot
  end

  # -- the root namespace ------------------------------------------------------

  def test_the_root_namespace_is_the_one_the_module_delegates_to
    define_standard_dials

    assert_same Dials.default.registry, Dials.registry
    assert_same Dials.default.store, Dials.store
    assert_same Dials.default.cache, Dials.cache
    assert_equal :default, Dials.default.name

    Dials.default.adjust_merchant_fee_bps(250, actor: ACTOR)
    assert_equal 250, Dials.merchant_fee_bps(market: "KE")
  end
end

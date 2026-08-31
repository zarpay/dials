# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "dials"
require "minitest/autorun"

module DialsTestSupport
  # Every test starts from a blank slate: empty registry, fresh in-memory
  # store, no cache.
  def setup
    Dials.registry.reset!
    Dials.instance_variable_set(:@config, nil)
    Dials.reset_cache!
    super
  end

  ACTOR = "test-operator"

  def define_standard_dials
    Dials.define do
      dial :merchant_fee_bps, 100, type: :integer, bounds: 1..10_000, unit: "bps",
           variants: { market: { options: %w[KE NG BD] } }
      dial :signups_enabled, true, type: :boolean
      dial :free_delivery_threshold, 50, type: :integer, bounds: 0..1_000_000,
           variants: { market: { options: %w[KE NG BD] }, platform: { options: %w[ios android web] } }
      dial :support_email, "support@example.com", type: :string
    end
  end
end

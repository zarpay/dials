# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "dials"
require "minitest/autorun"

module DialsTestSupport
  # Every test starts from a blank slate: empty registry, fresh in-memory
  # store, no cache.
  def setup
    Dials.registry.reset!
    Dials.instance_variable_set(:@config, Dials::Config.new)
    Dials.reset_cache!
    Thread.current[Dials::TXN_WRITE_KEY] = nil
    super
  end

  ACTOR = "test-operator"

  def define_standard_dials
    Dials.define do
      dial :merchant_fee_bps, default: 100, type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
           dimensions: { market: { enum: %w[KE NG BD] } }
      dial :signups_enabled, default: true, type: :boolean
      dial :free_delivery_threshold, default: 50, type: :integer, minimum: 0, maximum: 1_000_000,
           dimensions: { market: { enum: %w[KE NG BD] }, platform: { enum: %w[ios android web] } }
      dial :support_email, default: "support@example.com", type: :string
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

# The registry-integrity spec: pins exactly which dials this app declares and
# which of them are armed for variation. Adding a dial, adding variants to a
# dial, or widening a dimension's options makes this spec fail — which is the
# point: those changes deserve a visible, reviewed diff, because each one
# changes what operators can do in production.
RSpec.describe "Dial registry", type: :model do
  it "declares exactly the expected dials" do
    expect(Dials.registry.keys).to contain_exactly(
      :checkout_fee_bps,
      :free_delivery_threshold,
      :signups_enabled,
      :support_email,
      :welcome_banner
    )
  end

  it "pins which dials are armed for variation, and along which dimensions" do
    armed = Dials.registry.select(&:variants?).to_h { |d| [d.key, d.dimension_names] }
    expect(armed).to eq(
      checkout_fee_bps: [:market],
      free_delivery_threshold: %i[market platform],
      welcome_banner: [:locale]
    )
  end

  it "keeps the kill switch global-only" do
    expect(Dials.registry.fetch(:signups_enabled).variants?).to be(false)
  end

  it "pins market and platform options" do
    fee = Dials.registry.fetch(:checkout_fee_bps)
    expect(fee.dimensions.first.options).to eq(%w[KE NG BD])

    delivery = Dials.registry.fetch(:free_delivery_threshold)
    expect(delivery.dimensions.map(&:options)).to eq([%w[KE NG BD], %w[ios android web]])
  end

  it "gives every dial a description (operators read these)" do
    expect(Dials.registry.all).to all(have_attributes(description: be_present))
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe Pricing::QuoteService do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }

  it "prices with code defaults out of the box" do
    quote = described_class.new(market: "KE", platform: "ios").quote(10_000)
    expect(quote.fee_cents).to eq(250)        # 250 bps of 10_000
    expect(quote.free_delivery).to be(true)   # 10_000 >= 5_000 default
    expect(quote.total_cents).to eq(10_250)
  end

  it "picks up a per-market fee variation without the service changing" do
    Dials.set(:checkout_fee_bps, 100, scope: { market: "BD" }, actor: actor)

    bd = described_class.new(market: "BD", platform: "ios").quote(10_000)
    ke = described_class.new(market: "KE", platform: "ios").quote(10_000)

    expect(bd.fee_cents).to eq(100)
    expect(ke.fee_cents).to eq(250)
  end

  it "applies market × platform delivery thresholds" do
    Dials.set(:free_delivery_threshold, 20_000, scope: { market: "KE", platform: "web" }, actor: actor)

    web = described_class.new(market: "KE", platform: "web").quote(10_000)
    ios = described_class.new(market: "KE", platform: "ios").quote(10_000)

    expect(web.free_delivery).to be(false)
    expect(ios.free_delivery).to be(true)
  end

  it "is testable with pinned dials instead of store writes" do
    Dials::Testing.with_overrides(checkout_fee_bps: 1_000) do
      quote = described_class.new(market: "NG", platform: "android").quote(10_000)
      expect(quote.fee_cents).to eq(1_000)
    end
  end
end

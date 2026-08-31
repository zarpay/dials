# frozen_string_literal: true

require "rails_helper"

# The gem's resolution contract, proven against the real ActiveRecord store:
#   variation → global override → code default
RSpec.describe "Dial resolution", type: :model do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }

  it "serves the code default when nothing is stored" do
    expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(250)
    expect(Dials::ActiveRecord::Setting.count).to eq(0)
  end

  it "layers global override and variation, and clears back down layer by layer" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)
    Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: actor)

    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(120) # variation
    expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(300) # global override

    Dials.clear(:checkout_fee_bps, scope: { market: "BD" }, actor: actor)
    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(300) # back to global

    Dials.clear(:checkout_fee_bps, actor: actor)
    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(250) # back to code default
  end

  it "keeps a variation alive when the global override is cleared" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)
    Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: actor)
    Dials.clear(:checkout_fee_bps, actor: actor)

    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(120)
    expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(250)
  end

  it "stores and serves false (the kill-switch requirement)" do
    Dials.set(:signups_enabled, false, actor: actor)
    Dials.reload!
    expect(Dials.get(:signups_enabled)).to be(false)
  end

  it "resolves multi-dimension scopes exactly" do
    Dials.set(:free_delivery_threshold, 2_500, scope: { market: "KE", platform: "ios" }, actor: actor)

    expect(Dials.get(:free_delivery_threshold, market: "KE", platform: "ios")).to eq(2_500)
    expect(Dials.get(:free_delivery_threshold, market: "KE", platform: "web")).to eq(5_000)
    expect(Dials.get(:free_delivery_threshold, market: "NG", platform: "ios")).to eq(5_000)
  end

  it "round-trips json dials (string keys, like any JSON API)" do
    Dials.set(:welcome_banner, { "headline" => "Karibu!", "cta" => "Anza" }, scope: { locale: "sw" }, actor: actor)
    Dials.reload!
    expect(Dials.get(:welcome_banner, locale: "sw")).to eq({ "headline" => "Karibu!", "cta" => "Anza" })
    expect(Dials.get(:welcome_banner, locale: "en")["headline"]).to eq("Welcome to Bazario")
  end

  it "rejects reads with wrong scopes" do
    expect { Dials.get(:checkout_fee_bps) }.to raise_error(Dials::InvalidScope)
    expect { Dials.get(:checkout_fee_bps, market: "US") }.to raise_error(Dials::InvalidScope)
    expect { Dials.get(:signups_enabled, market: "KE") }.to raise_error(Dials::InvalidScope)
    expect { Dials.get(:free_delivery_threshold, market: "KE") }.to raise_error(Dials::InvalidScope)
  end

  it "rejects writes that violate type or bounds" do
    expect { Dials.set(:checkout_fee_bps, "300", actor: actor) }.to raise_error(Dials::InvalidValue)
    expect { Dials.set(:checkout_fee_bps, 0, actor: actor) }.to raise_error(Dials::InvalidValue)
    expect { Dials.set(:support_email, "not-an-email", actor: actor) }.to raise_error(Dials::InvalidValue)
  end

  it "rejects unattributed writes" do
    expect { Dials.set(:checkout_fee_bps, 300, actor: nil) }.to raise_error(Dials::MissingActor)
  end
end

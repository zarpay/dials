# frozen_string_literal: true

require "rails_helper"

# The gem's resolution contract, proven against the real ActiveRecord store:
#   scoped override → global override → code default
RSpec.describe "Dial resolution", type: :model do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }

  it "serves the code default when nothing is stored" do
    expect(Dials.checkout_fee_bps(market: "KE")).to eq(250)
    expect(Dials::ActiveRecord::Entry.count).to eq(0)
  end

  it "layers global and scoped overrides, and clears back down layer by layer" do
    Dials.adjust_checkout_fee_bps(300, actor: actor)
    Dials.adjust_checkout_fee_bps(120, actor: actor, market: "BD")

    expect(Dials.checkout_fee_bps(market: "BD")).to eq(120) # scoped override
    expect(Dials.checkout_fee_bps(market: "KE")).to eq(300) # global override

    Dials.clear_checkout_fee_bps(actor: actor, market: "BD")
    expect(Dials.checkout_fee_bps(market: "BD")).to eq(300) # back to global

    Dials.clear_checkout_fee_bps(actor: actor)
    expect(Dials.checkout_fee_bps(market: "BD")).to eq(250) # back to code default
  end

  it "keeps a scoped override alive when the global is cleared" do
    Dials.adjust_checkout_fee_bps(300, actor: actor)
    Dials.adjust_checkout_fee_bps(120, actor: actor, market: "BD")
    Dials.clear_checkout_fee_bps(actor: actor)

    expect(Dials.checkout_fee_bps(market: "BD")).to eq(120)
    expect(Dials.checkout_fee_bps(market: "KE")).to eq(250)
  end

  it "stores and serves false (the kill-switch requirement)" do
    Dials.adjust_signups_enabled(false, actor: actor)
    Dials.reload!
    expect(Dials.signups_enabled).to be(false)
  end

  it "resolves multi-dimension scopes exactly" do
    Dials.adjust_free_delivery_threshold(2_500, actor: actor, market: "KE", platform: "ios")

    expect(Dials.free_delivery_threshold(market: "KE", platform: "ios")).to eq(2_500)
    expect(Dials.free_delivery_threshold(market: "KE", platform: "web")).to eq(5_000)
    expect(Dials.free_delivery_threshold(market: "NG", platform: "ios")).to eq(5_000)
  end

  it "round-trips json dials (string keys, like any JSON API)" do
    Dials.adjust_welcome_banner({ "headline" => "Karibu!", "cta" => "Anza" }, actor: actor, locale: "sw")
    Dials.reload!
    expect(Dials.welcome_banner(locale: "sw")).to eq({ "headline" => "Karibu!", "cta" => "Anza" })
    expect(Dials.welcome_banner(locale: "en")["headline"]).to eq("Welcome to Bazario")
  end

  it "rejects reads with wrong scopes" do
    expect { Dials.checkout_fee_bps }.to raise_error(Dials::InvalidScope)
    expect { Dials.checkout_fee_bps(market: "US") }.to raise_error(Dials::InvalidScope)
    expect { Dials.signups_enabled(market: "KE") }.to raise_error(Dials::InvalidScope)
    expect { Dials.free_delivery_threshold(market: "KE") }.to raise_error(Dials::InvalidScope)
  end

  it "rejects writes that violate type or bounds" do
    expect { Dials.adjust_checkout_fee_bps("300", actor: actor) }.to raise_error(Dials::InvalidValue)
    expect { Dials.adjust_checkout_fee_bps(0, actor: actor) }.to raise_error(Dials::InvalidValue)
    expect { Dials.adjust_support_email("not-an-email", actor: actor) }.to raise_error(Dials::InvalidValue)
  end

  it "rejects unattributed writes" do
    expect { Dials.adjust_checkout_fee_bps(300, actor: nil) }.to raise_error(Dials::MissingActor)
  end

  it "exposes the same contract through the key-taking primitives (dynamic access)" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)
    Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: actor)

    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(120)
    expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(300)

    Dials.clear(:checkout_fee_bps, scope: { market: "BD" }, actor: actor)
    expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(300)
  end
end

# frozen_string_literal: true

require "rails_helper"

# The enumeration API (Dials.variations / Dials.overview) and stale-write
# protection (expected_version:), proven against the real ActiveRecord store.
RSpec.describe "Dial enumeration and stale-write protection", type: :model do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }

  describe "Dials.variations" do
    it "answers 'which markets have an override for this dial'" do
      Dials.adjust_checkout_fee_bps(120, actor: actor, market: "BD")
      Dials.adjust_checkout_fee_bps(180, actor: actor, market: "NG")

      expect(Dials.variations(:checkout_fee_bps)).to eq(
        { market: "BD" } => 120,
        { market: "NG" } => 180
      )
      expect(Dials.variations(:checkout_fee_bps).keys.map { |s| s[:market] }).to contain_exactly("BD", "NG")
    end

    it "returns {} for dials with nothing stored and raises for unknown keys" do
      expect(Dials.variations(:signups_enabled)).to eq({})
      expect { Dials.variations(:nope) }.to raise_error(Dials::UnknownDial)
    end
  end

  describe "Dials.overview" do
    it "renders the whole dashboard picture in one coherent call" do
      Dials.adjust_signups_enabled(false, actor: actor)
      Dials.adjust_free_delivery_threshold(2_500, actor: actor, market: "KE", platform: "ios")

      overview = Dials.overview
      expect(overview.version).to be_a(String)
      expect(overview.dials.map(&:key)).to eq(Dials.registry.keys)

      switch = overview.dials.find { |d| d.key == :signups_enabled }
      expect(switch.global_override?).to be(true)
      expect(switch.global_value).to be(false) # false override ≠ absent

      threshold = overview.dials.find { |d| d.key == :free_delivery_threshold }
      expect(threshold.global_override?).to be(false)
      expect(threshold.variations).to eq({ { market: "KE", platform: "ios" } => 2_500 })
      expect(threshold.json_schema).to include("type" => "integer", "minimum" => 0)
    end
  end

  describe "expected_version: (compare-and-swap)" do
    it "chains tokens through sequential writes" do
      token = Dials.overview.version
      token = Dials.adjust_checkout_fee_bps(300, actor: actor, expected_version: token)
      token = Dials.adjust_checkout_fee_bps(310, actor: actor, expected_version: token)
      Dials.clear_checkout_fee_bps(actor: actor, expected_version: token)

      expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(250)
      expect(Dials.changes.length).to eq(3)
    end

    it "refuses a stale write with nothing applied and nothing logged" do
      version = Dials.overview.version
      Dials.adjust_checkout_fee_bps(300, actor: actor)

      expect do
        Dials.adjust_checkout_fee_bps(999, actor: actor, expected_version: version)
      end.to raise_error(Dials::StaleWrite)

      expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(300)
      expect(Dials.changes.length).to eq(1)
      expect(Dials::ActiveRecord::Change.count).to eq(1)
    end
  end
end

# frozen_string_literal: true

require "rails_helper"

RSpec.describe Onboarding::SignupPolicy do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }

  it "allows signups by default" do
    expect(described_class.allowed?).to be(true)
  end

  it "stops everywhere when the kill switch is flipped to false" do
    Dials.set(:signups_enabled, false, actor: actor)
    expect(described_class.allowed?).to be(false)
  end

  it "can be flipped back on (false → true → false round trips)" do
    Dials.set(:signups_enabled, false, actor: actor)
    Dials.set(:signups_enabled, true, actor: actor)
    expect(described_class.allowed?).to be(true)
  end

  it "cannot be given a per-market value — the switch is global by design" do
    expect do
      Dials.set(:signups_enabled, false, scope: { market: "KE" }, actor: actor)
    end.to raise_error(Dials::InvalidScope)
  end

  it "pins cleanly in tests" do
    Dials::Testing.with_overrides(signups_enabled: false) do
      expect(described_class.allowed?).to be(false)
    end
    expect(described_class.allowed?).to be(true)
  end
end

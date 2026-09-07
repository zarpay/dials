# frozen_string_literal: true

require "rails_helper"

# Testing domain code that consumes a NAMESPACE's dials: pin through the
# namespace object, exactly as app code pins through Dials::Testing.
RSpec.describe Courier::ParcelPolicy, type: :model do
  it "accepts a parcel at the code default" do
    expect(described_class.new(market: "KE").accepts?(20)).to be(true)
    expect(described_class.new(market: "KE").accepts?(21)).to be(false)
  end

  it "follows a pinned per-market limit" do
    CourierDials.with_overrides(max_parcel_kg: 5) do
      expect(described_class.new(market: "BD").accepts?(5)).to be(true)
      expect(described_class.new(market: "BD").accepts?(6)).to be(false)
    end
  end
end

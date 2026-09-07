# frozen_string_literal: true

module Courier
  # A consumer inside the namespace's own subsystem. It reads through the
  # namespace object exactly as app code reads through `Dials` — same
  # generated readers, same resolution, different owner.
  class ParcelPolicy
    def initialize(market:)
      @market = market
    end

    def accepts?(weight_kg)
      weight_kg <= CourierDials.max_parcel_kg(market: @market)
    end
  end
end

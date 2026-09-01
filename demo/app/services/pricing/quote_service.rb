# frozen_string_literal: true

module Pricing
  # Prices a checkout for one order in one (market, platform) context.
  #
  # This is the canonical dial CONSUMER: it never knows whether the value it
  # reads is the code default, a global override, or a per-market variation —
  # that layering is the gem's job. It just asks for the value in its context.
  class QuoteService
    Quote = Data.define(:subtotal_cents, :fee_cents, :free_delivery, :total_cents)

    def initialize(market:, platform:)
      @market = market
      @platform = platform
    end

    def quote(subtotal_cents)
      fee_bps = Dials.use_checkout_fee_bps(market: @market)
      threshold = Dials.use_free_delivery_threshold(market: @market, platform: @platform)

      fee_cents = (subtotal_cents * fee_bps) / 10_000
      Quote.new(
        subtotal_cents: subtotal_cents,
        fee_cents: fee_cents,
        free_delivery: subtotal_cents >= threshold,
        total_cents: subtotal_cents + fee_cents
      )
    end
  end
end

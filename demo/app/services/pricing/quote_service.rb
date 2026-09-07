# frozen_string_literal: true

module Pricing
  # Prices a checkout for one order in one (market, platform) context.
  #
  # This is the canonical dial CONSUMER: it never knows whether the value it
  # reads is the code default, a global override, or a per-market override —
  # that layering is the gem's job. It just asks for the value in its context.
  class QuoteService
    Quote = Data.define(:subtotal_cents, :fee_cents, :free_delivery, :total_cents)

    def initialize(market:, platform:)
      @market = market
      @platform = platform
    end

    # The "no scope to give" consumer: a ballpark quote for an anonymous
    # visitor whose market and platform are not knowable yet. Dials.global
    # reads each dial's Global layer — the stored global override when
    # present, else the code default — which is the honest answer when no
    # per-market override can apply. This is NOT a way to skip a known
    # scope: a caller that knows its market must construct the service and
    # quote normally (a scopeless Dials.checkout_fee_bps raises).
    def self.estimate(subtotal_cents)
      fee_bps = Dials.global(:checkout_fee_bps)
      threshold = Dials.global(:free_delivery_threshold)

      fee_cents = (subtotal_cents * fee_bps) / 10_000
      Quote.new(
        subtotal_cents: subtotal_cents,
        fee_cents: fee_cents,
        free_delivery: subtotal_cents >= threshold,
        total_cents: subtotal_cents + fee_cents
      )
    end

    def quote(subtotal_cents)
      fee_bps = Dials.checkout_fee_bps(market: @market)
      threshold = Dials.free_delivery_threshold(market: @market, platform: @platform)

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

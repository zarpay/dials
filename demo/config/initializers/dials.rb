# frozen_string_literal: true

# =============================================================================
# The demo app's dial registry
# =============================================================================
#
# This app plays "Bazario", a fictional commerce platform operating in three
# markets (KE, NG, BD) across three platforms (ios, android, web). Its dials
# exercise every declaration shape the gem supports:
#
#   checkout_fee_bps        integer, Range bounds, ONE variant dimension
#   free_delivery_threshold integer, TWO variant dimensions (market × platform)
#   signups_enabled         boolean kill switch, global-only (no variants:)
#   support_email           string, global-only, callable bounds
#   feature_copy            json, open "locale" dimension (no options list)
#
# Declarations live here, in code, under code review. The database stores
# only overrides: nothing below writes a row, and dropping every row returns
# the app to exactly these defaults.
#
# A dial with no `variants:` is global-only by construction. Declaring
# `variants:` is the arming gate — it ships in the same PR as the code that
# reads the varied value (for this app, the services in app/services).

require "dials/active_record"

markets = %w[KE NG BD]
platforms = %w[ios android web]

Dials.configure do |config|
  # :active_record in every environment — the spec suite exercises real
  # persistence (see spec/support/dials.rb for the per-example reset).
  config.store = :active_record
  config.cache_ttl = 5.0
  config.actor_label = ->(actor) { actor.respond_to?(:email) ? actor.email : actor.to_s }
end

Dials.define do
  dial :checkout_fee_bps, 250,
       type: :integer,
       bounds: 1..10_000,
       unit: "bps",
       description: "Fee charged on checkout, in basis points of the order total.",
       variants: { market: { options: markets } }

  dial :free_delivery_threshold, 5_000,
       type: :integer,
       bounds: 0..1_000_000,
       unit: "cents",
       description: "Order totals at or above this ship free.",
       variants: { market: { options: markets }, platform: { options: platforms } }

  dial :signups_enabled, true,
       type: :boolean,
       description: "Global kill switch for new signups. Deliberately global-only: " \
                    "when things are on fire you want one switch, not one per market."

  dial :support_email, "support@bazario.example",
       type: :string,
       bounds: ->(value) { value.match?(URI::MailTo::EMAIL_REGEXP) },
       description: "Reply-to address shown across the product."

  dial :welcome_banner, { "headline" => "Welcome to Bazario", "cta" => "Start shopping" },
       type: :json,
       description: "Structured homepage banner copy.",
       variants: { locale: {} } # open dimension: any non-empty locale string
end

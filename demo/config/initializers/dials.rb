# frozen_string_literal: true

# =============================================================================
# The demo app's dial registry
# =============================================================================
#
# This app plays "Bazario", a fictional commerce platform operating in three
# markets (KE, NG, BD) across three platforms (ios, android, web). Its dials
# exercise every declaration shape the gem supports:
#
#   checkout_fee_bps        integer, min/max, ONE dimension
#   free_delivery_threshold integer, TWO dimensions (market × platform)
#   signups_enabled         boolean kill switch, global-only (no dimensions:)
#   support_email           string, global-only, callable bounds
#   feature_copy            json, open "locale" dimension (no options list)
#
# Declarations live here, in code, under code review. The database stores
# only overrides: nothing below writes a row, and dropping every row returns
# the app to exactly these defaults.
#
# A dial with no `dimensions:` is global-only by construction. Declaring
# `dimensions:` is the arming gate — it ships in the same PR as the code that
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
  dial :checkout_fee_bps, default: 250,
       type: :integer,
       minimum: 1,
       maximum: 10_000,
       unit: "bps",
       description: "Fee charged on checkout, in basis points of the order total.",
       dimensions: { market: { enum: markets } }

  dial :free_delivery_threshold, default: 5_000,
       type: :integer,
       minimum: 0,
       maximum: 1_000_000,
       unit: "cents",
       description: "Order totals at or above this ship free.",
       dimensions: { market: { enum: markets }, platform: { enum: platforms } }

  dial :signups_enabled, default: true,
       type: :boolean,
       description: "Global kill switch for new signups. Deliberately global-only: " \
                    "when things are on fire you want one switch, not one per market."

  dial :support_email, default: "support@bazario.example",
       type: :string,
       pattern: URI::MailTo::EMAIL_REGEXP,
       max_length: 254,
       description: "Reply-to address shown across the product."

  dial :welcome_banner, default: { "headline" => "Welcome to Bazario", "cta" => "Start shopping" },
       type: :json,
       properties: { "headline" => { type: :string, min_length: 1 },
                     "cta" => { type: :string, min_length: 1 } },
       required: %w[headline cta],
       description: "Structured homepage banner copy.",
       dimensions: { locale: {} } # open dimension: any non-empty locale string
end

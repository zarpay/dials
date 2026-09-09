# frozen_string_literal: true

# =============================================================================
# The Courier subsystem's namespace
# =============================================================================
#
# Bazario's courier integration is the kind of thing that would ship as an
# engine: it owns its operator settings end to end. A namespace gives it a
# full dials instance — its own registry, store, table (courier_dials),
# cache, change log and generated readers — without putting a single row in
# the app's `dials` table.
#
# Note `support_email`: the app declares that key too, with a different
# default. A key is unique inside its namespace, not across the app, so the
# two never see each other. There is no cross-namespace fallback either — a
# dial resolves scoped override -> global override -> code default, inside
# its own namespace.
#
# This file loads after config/initializers/dials.rb only by alphabetical
# accident, and it does not matter: `store` is not set here, so it inherits
# the root's KIND (:active_record) against this namespace's own table, and
# cache_ttl and actor_label read through to the root's config.

# The constant is CourierDials, not Courier: Zeitwerk owns `Courier` for the
# subsystem's own classes (app/services/courier). A namespace object and an
# autoloaded module cannot share a name.
CourierDials = Dials.namespace(:courier, label: "Courier")

CourierDials.define do
  dial :max_parcel_kg, default: 20,
       type: :integer,
       minimum: 1,
       maximum: 50,
       unit: "kg",
       description: "Heaviest parcel a courier will accept.",
       dimensions: { market: { enum: %w[KE NG BD] } }

  dial :support_email, default: "couriers@bazario.example",
       type: :string,
       pattern: URI::MailTo::EMAIL_REGEXP,
       max_length: 254,
       description: "Where a courier reports a problem. Not the app's support_email."
end

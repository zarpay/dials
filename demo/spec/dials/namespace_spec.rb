# frozen_string_literal: true

require "rails_helper"

# What a namespace owns, proven against a real Rails app and two real
# tables — the app's `dials` and the Courier subsystem's `courier_dials`.
RSpec.describe "Dial namespaces", type: :model do
  let(:actor) { AdminUser.new(id: 77, email: "ops@bazario.example") }

  it "lists the root first, then declaration order" do
    expect(Dials.namespaces.map(&:name)).to eq(%i[default courier])
    expect(Dials.namespaces.map(&:label)).to eq(["Dials", "Courier"])
    expect(Dials.namespace(:courier)).to be(CourierDials)
    expect(Dials.default.registry.keys).not_to include(:max_parcel_kg)
  end

  it "gives the same key a different value in each namespace" do
    expect(Dials.support_email).to eq("support@bazario.example")
    expect(CourierDials.support_email).to eq("couriers@bazario.example")

    Dials.adjust_support_email("help@bazario.example", actor: actor)

    expect(Dials.support_email).to eq("help@bazario.example")
    expect(CourierDials.support_email).to eq("couriers@bazario.example")
  end

  it "writes each namespace's rows to its own table" do
    Dials.adjust_support_email("help@bazario.example", actor: actor)
    CourierDials.adjust_max_parcel_kg(30, actor: actor, market: "KE")

    expect(Dials::ActiveRecord::Entry.pluck(:key)).to eq(%w[support_email])
    expect(CourierDials.store.model.table_name).to eq("courier_dials")
    expect(CourierDials.store.model.pluck(:key)).to eq(%w[max_parcel_kg])
  end

  it "keeps each namespace's change log to itself" do
    Dials.adjust_support_email("help@bazario.example", actor: actor)
    CourierDials.adjust_max_parcel_kg(30, actor: actor, market: "KE")

    expect(Dials.changes.map(&:key)).to eq(%i[support_email])
    expect(CourierDials.changes.map(&:key)).to eq(%i[max_parcel_kg])
    expect(CourierDials.changes.sole.actor_label).to eq("ops@bazario.example")
  end

  it "resolves scoped override → global override → code default inside the namespace" do
    CourierDials.adjust_max_parcel_kg(25, actor: actor)
    CourierDials.adjust_max_parcel_kg(10, actor: actor, market: "BD")

    expect(CourierDials.max_parcel_kg(market: "BD")).to eq(10)
    expect(CourierDials.max_parcel_kg(market: "KE")).to eq(25)

    CourierDials.clear_max_parcel_kg(actor: actor, market: "BD")
    expect(CourierDials.max_parcel_kg(market: "BD")).to eq(25)
  end

  it "inherits the root's config for options it does not set" do
    # The Courier initializer sets no store and no cache_ttl.
    expect(CourierDials.config.cache_ttl).to eq(Dials.config.cache_ttl)
    expect(CourierDials.store).to be_a(Dials::Stores::ActiveRecordStore)
    expect(CourierDials.store).not_to be(Dials.store)
  end

  it "pins one namespace's dials without touching another's" do
    CourierDials.with_overrides(support_email: "pinned@bazario.example") do
      expect(CourierDials.support_email).to eq("pinned@bazario.example")
      expect(Dials.support_email).to eq("support@bazario.example")
    end

    expect(CourierDials.support_email).to eq("couriers@bazario.example")
  end

  it "refuses a dial the namespace does not declare" do
    expect { CourierDials.get(:checkout_fee_bps, market: "KE") }.to raise_error(Dials::UnknownDial)
    expect { Dials.get(:max_parcel_kg, market: "KE") }.to raise_error(Dials::UnknownDial)
  end
end

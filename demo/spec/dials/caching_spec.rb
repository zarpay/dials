# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dial caching", type: :model do
  let(:actor) { AdminUser.new(id: 99, email: "ops@bazario.example") }
  let(:foreign_actor) { { actor_type: nil, actor_id: nil, actor_label: "another-process" } }

  after { Dials.config.cache_ttl = 5.0 }

  it "reads its own writes immediately, regardless of ttl" do
    Dials.config.cache_ttl = 3600
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(250)
    Dials.adjust_checkout_fee_bps(300, actor: actor)
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(300)
  end

  it "does not see another process's write until the staleness probe runs" do
    Dials.config.cache_ttl = 3600
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(250)

    # Another process = a write through the store that never touches this
    # process's cache.
    Dials.store.set_global(:checkout_fee_bps, 400, foreign_actor)

    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(250) # still cached
    Dials.reload!
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(400)
  end

  it "converges automatically with ttl 0 (probe every read)" do
    Dials.config.cache_ttl = 0
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(250)
    Dials.store.set_global(:checkout_fee_bps, 400, foreign_actor)
    expect(Dials.use_checkout_fee_bps(market: "KE")).to eq(400)
  end

  it "serves reads from the snapshot without querying per read" do
    Dials.config.cache_ttl = 3600
    Dials.use_checkout_fee_bps(market: "KE") # warm

    queries = 0
    counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      100.times { Dials.use_checkout_fee_bps(market: "KE") }
    end
    expect(queries).to eq(0)
  end
end

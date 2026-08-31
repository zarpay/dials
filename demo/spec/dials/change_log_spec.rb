# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Dial change log", type: :model do
  let(:actor) { AdminUser.new(id: 7, email: "keith@bazario.example") }

  it "attributes every write with type, id, and label" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)

    change = Dials.changes.first
    expect(change.actor_type).to eq("AdminUser")
    expect(change.actor_id).to eq("7")
    expect(change.actor_label).to eq("keith@bazario.example") # via config.actor_label
  end

  it "records old and new values through a set/set/clear lifecycle" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)
    Dials.set(:checkout_fee_bps, 400, actor: actor)
    Dials.clear(:checkout_fee_bps, actor: actor)

    changes = Dials.changes(key: :checkout_fee_bps)
    expect(changes.map(&:action)).to eq(%w[clear set set])
    expect(changes.map(&:new_value)).to eq([nil, 400, 300])
    expect(changes.map(&:old_value)).to eq([400, 300, nil])
  end

  it "records the scope on variation changes" do
    Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: actor)
    change = Dials.changes.first
    expect(change.scope).to eq(market: "BD")
    expect(change.global?).to be(false)
  end

  it "does not log no-op clears" do
    Dials.clear(:checkout_fee_bps, actor: actor)
    expect(Dials.changes).to be_empty
  end

  it "persists to the dial_changes table (append-only, created_at only)" do
    Dials.set(:checkout_fee_bps, 300, actor: actor)
    row = Dials::ActiveRecord::Change.sole
    expect(row.key).to eq("checkout_fee_bps")
    expect(row).not_to respond_to(:updated_at)
  end
end

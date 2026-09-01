# frozen_string_literal: true

require "rails_helper"

# The hand-built write surface: proves the controller-level contract a client
# app implements on top of the gem — attribution from the authenticated
# admin, typed validation errors as HTTP statuses, and the change log as an
# API resource.
RSpec.describe "Admin dials API", type: :request do
  let(:headers) { { "X-Admin-Email" => "keith@bazario.example", "CONTENT_TYPE" => "application/json" } }

  def put_dial(key, body)
    put "/admin/dials/#{key}", params: body.to_json, headers: headers
  end

  describe "GET /admin/dials" do
    it "renders the registry for UI building" do
      get "/admin/dials", headers: headers
      expect(response).to have_http_status(:ok)

      dials = response.parsed_body.index_by { |d| d["key"] }
      expect(dials.keys).to match_array(%w[checkout_fee_bps free_delivery_threshold signups_enabled support_email welcome_banner])

      fee = dials["checkout_fee_bps"]
      expect(fee["default"]).to eq(250)
      expect(fee["unit"]).to eq("bps")
      expect(fee["dimensions"]).to eq([{ "name" => "market", "enum" => %w[KE NG BD] }])
    end
  end

  describe "PUT /admin/dials/:key" do
    it "sets a global override" do
      put_dial(:checkout_fee_bps, { value: 300 })
      expect(response).to have_http_status(:no_content)
      expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(300)
    end

    it "sets a variation" do
      put_dial(:checkout_fee_bps, { value: 120, scope: { market: "BD" } })
      expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(120)
      expect(Dials.get(:checkout_fee_bps, market: "KE")).to eq(250)
    end

    it "accepts false over the wire (kill switch off)" do
      put_dial(:signups_enabled, { value: false })
      expect(response).to have_http_status(:no_content)
      expect(Dials.get(:signups_enabled)).to be(false)
    end

    it "attributes the change to the authenticated admin" do
      put_dial(:checkout_fee_bps, { value: 300 })
      expect(Dials.changes.first.actor_label).to eq("keith@bazario.example")
    end

    it "rejects schema-violating values as 422 with the gem's message" do
      put_dial(:checkout_fee_bps, { value: 0 })
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]).to match(/must be >= 1/)
    end

    it "rejects invalid scopes as 422" do
      put_dial(:checkout_fee_bps, { value: 100, scope: { market: "US" } })
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "404s unknown dials" do
      put_dial(:no_such_dial, { value: 1 })
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /admin/dials/:key" do
    it "clears a variation back to the global layer" do
      put_dial(:checkout_fee_bps, { value: 120, scope: { market: "BD" } })
      delete "/admin/dials/checkout_fee_bps", params: { scope: { market: "BD" } }.to_json, headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Dials.get(:checkout_fee_bps, market: "BD")).to eq(250)
    end
  end

  describe "GET /admin/dials/:key/changes" do
    it "exposes the attributed history" do
      put_dial(:checkout_fee_bps, { value: 300 })
      put_dial(:checkout_fee_bps, { value: 120, scope: { market: "BD" } })

      get "/admin/dials/checkout_fee_bps/changes", headers: headers
      history = response.parsed_body
      expect(history.length).to eq(2)
      expect(history.first["new_value"]).to eq(120)
      expect(history.first["scope"]).to eq({ "market" => "BD" })
      expect(history.last["scope"]).to be_nil
    end
  end
end

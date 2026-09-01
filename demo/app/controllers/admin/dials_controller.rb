# frozen_string_literal: true

module Admin
  # The write surface a client app builds on top of the gem (v1 ships no GUI
  # by design — see the docs). This JSON controller demonstrates the whole
  # contract:
  #
  #   GET    /admin/dials            full state: definitions + overrides + version
  #   PUT    /admin/dials/:key       set an override   { value:, scope:, expected_version: }
  #   DELETE /admin/dials/:key       clear an override { scope:, expected_version: }
  #   GET    /admin/dials/:key/changes  attributed history
  #
  # Attribution: the authenticated admin is passed as actor: on every write.
  # Validation: the gem raises typed errors; they render as 422/404/409 here.
  #
  # Stale-write protection: each override in the index payload carries its
  # own version token (`global_version`, and `version` on every variation;
  # `absent_version` is the token for overrides the page shows as not
  # stored). A client that echoes the right token back as `expected_version`
  # can never overwrite a change it didn't see — the gem refuses with
  # StaleWrite (409 here), and the client re-renders from a fresh GET.
  #
  # This controller uses the key-taking primitives (Dials.get/set/clear and
  # Dials.overview) rather than the generated per-dial methods, because the
  # key arrives as a request param — this is exactly the dynamic-access case
  # the primitives exist for. Application code with the dial in hand uses the
  # generated forms (see app/services).
  class DialsController < ApplicationController
    rescue_from Dials::UnknownDial, with: -> { head :not_found }
    rescue_from Dials::InvalidValue, Dials::InvalidScope, Dials::MissingActor do |error|
      render json: { error: error.message }, status: :unprocessable_content
    end
    rescue_from Dials::StaleWrite do |error|
      render json: { error: error.message }, status: :conflict
    end

    def index
      overview = Dials.overview
      render json: {
        version: overview.version, # informational "rendered as of" stamp
        absent_version: Dials::ABSENT_VERSION,
        dials: overview.dials.map { |state| present(state) }
      }
    end

    def update
      result = Dials.set(dial_key, value_param, scope: scope_param, actor: current_admin,
                                                expected_version: expected_version_param)
      write_response(result)
    end

    def destroy
      result = Dials.clear(dial_key, scope: scope_param, actor: current_admin,
                           expected_version: expected_version_param)
      write_response(result)
    end

    def changes
      render json: Dials.changes(key: dial_key).map(&:to_h)
    end

    private

    def dial_key
      params[:key].to_sym
    end

    # NOT params.require(:value): require rejects blank values, and `false`
    # is blank — it would make a boolean kill switch impossible to turn off
    # over this API. fetch is key-presence based.
    def value_param
      value = params.fetch(:value)
      value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value
    end

    def scope_param
      params[:scope].respond_to?(:to_unsafe_h) ? params[:scope].to_unsafe_h : params[:scope]
    end

    def expected_version_param
      params[:expected_version].presence
    end

    # A CAS write returns the override's new token — hand it to the client
    # so sequential edits to the same override can chain without a re-fetch.
    def write_response(result)
      if expected_version_param
        render json: { version: result }
      else
        head :no_content
      end
    end

    # A real app plugs in its authentication here (Devise, ActiveAdmin, ...).
    def current_admin
      AdminUser.new(id: 1, email: request.headers.fetch("X-Admin-Email", "admin@bazario.example"))
    end

    # One dial's declaration AND stored state, from the coherent overview
    # snapshot. `global_override` stays an explicit boolean — a kill switch
    # overridden to false must never render as "no override".
    def present(state)
      definition = state.definition
      {
        key: definition.key,
        label: definition.label,
        type: definition.type,
        unit: definition.unit,
        description: definition.description,
        default: definition.default,
        schema: state.json_schema,
        dimensions: definition.dimensions.map { |d| { name: d.name, enum: d.enum } },
        global_override: state.global_override?,
        global_value: state.global_value,
        global_version: state.global_version,
        variations: state.variations.map do |scope, value|
          { scope: scope, value: value, version: state.variation_versions[scope] }
        end
      }
    end
  end
end

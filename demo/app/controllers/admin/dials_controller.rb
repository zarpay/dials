# frozen_string_literal: true

module Admin
  # The write surface a client app builds on top of the gem (v1 ships no GUI
  # by design — see the docs). This JSON controller demonstrates the whole
  # contract:
  #
  #   GET    /admin/dials            registry + resolved current values
  #   PUT    /admin/dials/:key       set an override   { value:, scope: }
  #   DELETE /admin/dials/:key       clear an override { scope: }
  #   GET    /admin/dials/:key/changes  attributed history
  #
  # Attribution: the authenticated admin is passed as actor: on every write.
  # Validation: the gem raises typed errors; they render as 422/400 here.
  #
  # This controller uses the key-taking primitives (Dials.get/set/clear)
  # rather than the generated per-dial methods, because the key arrives as a
  # request param — this is exactly the dynamic-access case the primitives
  # exist for. Application code with the dial in hand uses the generated
  # forms (see app/services).
  class DialsController < ApplicationController
    rescue_from Dials::UnknownDial, with: -> { head :not_found }
    rescue_from Dials::InvalidValue, Dials::InvalidScope, Dials::MissingActor do |error|
      render json: { error: error.message }, status: :unprocessable_content
    end

    def index
      render json: Dials.registry.map { |definition| present(definition) }
    end

    def update
      Dials.set(dial_key, value_param, scope: scope_param, actor: current_admin)
      head :no_content
    end

    def destroy
      Dials.clear(dial_key, scope: scope_param, actor: current_admin)
      head :no_content
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

    # A real app plugs in its authentication here (Devise, ActiveAdmin, ...).
    def current_admin
      AdminUser.new(id: 1, email: request.headers.fetch("X-Admin-Email", "admin@bazario.example"))
    end

    def present(definition)
      {
        key: definition.key,
        label: definition.label,
        type: definition.type,
        unit: definition.unit,
        description: definition.description,
        default: definition.default,
        dimensions: definition.dimensions.map { |d| { name: d.name, options: d.options } }
      }
    end
  end
end

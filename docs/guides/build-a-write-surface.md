# Build a Write Surface

The gem ships **no admin GUI** — deliberately. Every team's admin stack
(ActiveAdmin, Avo, hand-rolled, an internal SPA) already has authentication,
authorization, and styling that a bundled GUI would fight. What the gem
provides is everything a thin surface needs: the registry to render, typed
validated writes, attribution, and history.

The demo app's
[`Admin::DialsController`](https://github.com/zarpay/dials/blob/main/demo/app/controllers/admin/dials_controller.rb)
is the reference implementation. The essentials:

One note on API choice: this surface uses the key-taking primitives
(`Dials.get` / `Dials.set` / `Dials.clear`) rather than the generated
per-dial methods, because the dial key arrives as a request param — this is
exactly the dynamic-access case the primitives exist for. Application code
with the dial in hand uses `Dials.use_checkout_fee_bps(...)` and friends.

## Render from the registry

```ruby
def index
  render json: Dials.registry.map { |definition|
    {
      key: definition.key,
      label: definition.label,
      type: definition.type,
      unit: definition.unit,
      description: definition.description,
      default: definition.default,
      dimensions: definition.dimensions.map { |d| { name: d.name, enum: d.enum } }
    }
  }
end
```

The registry tells your UI everything: what dials exist, what inputs to
render (type), what to validate client-side (each definition's
`to_json_schema` feeds any JSON Schema validator; the server re-checks; render
`enum` values as selects), and what to label things. There is no "dial CRUD" —
dials are created in code, so the surface only edits *values*.

For each dial, show the resolved value per scope so operators see the
layering: `Dials.get(key, **scope)` per scope of interest, and mark which
cells are inherited (no variation row) versus overridden.

## Writes: pass the authenticated admin as actor

```ruby
def update
  Dials.set(dial_key, value_param, scope: scope_param, actor: current_admin)
  head :no_content
end

def destroy   # "clear" — return a cell to inheritance
  Dials.clear(dial_key, scope: scope_param, actor: current_admin)
  head :no_content
end
```

This is where your auth lives. The gem never guesses the actor; the
controller — which knows who is logged in and has checked authorization —
supplies it explicitly.

## Two hard-won details

**Do not use `params.require(:value)`.** Rails' `require` rejects *blank*
values, and `false` is blank — it would make a boolean kill switch impossible
to turn off over HTTP. Use key-presence instead:

```ruby
def value_param
  value = params.fetch(:value)                                 # key-presence, false-safe
  value.respond_to?(:to_unsafe_h) ? value.to_unsafe_h : value  # unwrap json-type hashes
end
```

**Map the typed errors, don't swallow them.** The gem's error messages are
written for operators; pass them through:

```ruby
rescue_from Dials::UnknownDial, with: -> { head :not_found }
rescue_from Dials::InvalidValue, Dials::InvalidScope do |error|
  render json: { error: error.message }, status: :unprocessable_content
end
```

## History

```ruby
def changes
  render json: Dials.changes(key: dial_key).map(&:to_h)
end
```

Render it as a timeline next to the dial, and consider surfacing
`old_value → new_value` with the actor label in a confirm step *before*
writes — an operator about to change a money-shaped number should see what
they're replacing.

## If you use ActiveAdmin / Avo

Register a page (not a resource — there's no model to CRUD) that renders
from `Dials.registry` and posts to the two write actions above. Do **not**
register the gem's internal models (`Dials::ActiveRecord::Setting` etc.) as
editable resources: direct model writes bypass validation, attribution, and
cache busting — all three of which are the point.

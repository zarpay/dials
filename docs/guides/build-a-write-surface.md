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

## Render from one overview

```ruby
def index
  overview = Dials.overview
  render json: {
    version: overview.version,   # echo back as expected_version on writes
    dials: overview.dials.map { |state|
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
        variations: state.variations.map { |scope, value| { scope: scope, value: value } }
      }
    }
  }
end
```

`Dials.overview` reads everything from ONE snapshot, so the page is a
coherent picture stamped with a single `version`. It tells your UI
everything: what dials exist, what inputs to render (type), what to validate
client-side (`schema` is a real JSON Schema fragment — feed it to any
validator; the server re-checks; render `enum` values as selects), which
cells are **inherited versus overridden** (`global_override` is an explicit
boolean — a kill switch overridden to `false` must never render as "no
override"), and which scopes have variations. There is no "dial CRUD" —
dials are created in code, so the surface only edits *values*. For the
resolved value in one specific context, `Dials.get(key, **scope)`;
for one dial's stored variations, `Dials.variations(key)`.

## Writes: pass the authenticated admin as actor

```ruby
def update
  Dials.set(dial_key, value_param, scope: scope_param, actor: current_admin,
                                   expected_version: params[:expected_version].presence)
  head :no_content
end

def destroy   # "clear" — return a cell to inheritance
  Dials.clear(dial_key, scope: scope_param, actor: current_admin,
              expected_version: params[:expected_version].presence)
  head :no_content
end
```

This is where your auth lives. The gem never guesses the actor; the
controller — which knows who is logged in and has checked authorization —
supplies it explicitly.

## Stale-write protection

Echo the overview's `version` back as `expected_version` and no operator can
ever overwrite a change they didn't see: the gem refuses the write with
`Dials::StaleWrite` (atomically — nothing applied, nothing logged) when the
store has moved since the page rendered. Map it to 409 and re-render:

```ruby
rescue_from Dials::StaleWrite do |error|
  render json: { error: error.message }, status: :conflict
end
```

On a 409 the client fetches a fresh overview, shows the operator what
changed, and lets them decide again — never auto-retry, which would defeat
the point. A successful CAS write returns the new version token, so
sequential edits from one page can chain without a re-fetch.

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

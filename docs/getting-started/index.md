# Quick Start

## Install

```bash
bundle add dials
bin/rails generate dials:install
bin/rails db:migrate
```

The generator creates one migration (three tables: `dials`,
`dial_variations`, `dial_changes`) and `config/initializers/dials.rb`.

## Declare your first dials

```ruby
# config/initializers/dials.rb
require "dials/active_record"

Dials.configure do |config|
  config.store = :active_record
end

Dials.define do
  dial :checkout_fee_bps, 250,
       type: :integer,
       bounds: 1..10_000,
       unit: "bps",
       description: "Fee charged on checkout, in basis points.",
       variants: { market: { options: %w[KE NG BD] } }

  dial :signups_enabled, true,
       type: :boolean,
       description: "Global kill switch for new signups."
end
```

Each `dial` takes a key, a **code default**, and:

| Option | Meaning |
|---|---|
| `type:` | `:boolean`, `:integer`, `:float`, `:string`, or `:json` |
| `bounds:` | optional — a `Range`, an `Array` of allowed values, or a callable |
| `variants:` | optional — the dial's variant dimensions (see below) |
| `label:` / `unit:` / `description:` | metadata for the admin surface you build |

A dial with no `variants:` is **global-only**: it can never hold per-scope
values, which is exactly what you want for a kill switch.

## Read

```ruby
Dials.get(:signups_enabled)                  # global-only dial: no scope
Dials.get(:checkout_fee_bps, market: "KE")   # varied dial: scope required
```

The scope must name **every** dimension the dial declares — a missing or
unknown dimension raises `Dials::InvalidScope` immediately, in development,
not quietly in production.

Reads cost a hash lookup. No query runs per `get` — see [Caching](/concepts/caching).

## Write

```ruby
# Global override (applies wherever no variation exists):
Dials.set(:checkout_fee_bps, 300, actor: current_admin)

# Per-market variation:
Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: current_admin)

# Remove overrides (each layer falls back to the one below):
Dials.clear(:checkout_fee_bps, scope: { market: "BD" }, actor: current_admin)
Dials.clear(:checkout_fee_bps, actor: current_admin)
```

`actor:` is required on every write — there is no anonymous mutation path.
Values are validated against the declared type and bounds before anything is
stored.

## History

```ruby
Dials.changes(key: :checkout_fee_bps)
# => newest-first array of ChangeRecord(key, scope, action, old_value,
#    new_value, actor_type, actor_id, actor_label, created_at)
```

## In tests

```ruby
Dials::Testing.with_overrides(checkout_fee_bps: 1_000) do
  # every read of :checkout_fee_bps returns 1_000, for any scope
end
```

And one line of hygiene in `rails_helper.rb` when using transactional specs:

```ruby
RSpec.configure { |config| config.before { Dials.reload! } }
```

See [Testing with Dials](/guides/testing) for why.

## Next

- [The Dial Model](/concepts/the-dial-model) — the resolution layers and why
  the database stores only overrides
- [Variants and Scopes](/concepts/variants-and-scopes) — dimensions, options,
  and the exact-scope rule
- [Retrofit a Constant](/guides/retrofit-a-constant) — adopting dials in an
  existing app

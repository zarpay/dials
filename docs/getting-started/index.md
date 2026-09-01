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
  dial :checkout_fee_bps, default: 250,
       type: :integer,
       minimum: 1,
       maximum: 10_000,
       unit: "bps",
       description: "Fee charged on checkout, in basis points.",
       variants: { market: { enum: %w[KE NG BD] } }

  dial :signups_enabled, default: true,
       type: :boolean,
       description: "Global kill switch for new signups."
end
```

Each `dial` takes a key and:

| Option | Meaning |
|---|---|
| `default:` | the **code default** — what the dial serves until an operator overrides it |
| `type:` | `:boolean`, `:integer`, `:float`, `:string`, or `:json` |
| *constraints* | optional JSON Schema keywords for the type — `minimum:`/`maximum:` for numbers, `min_length:`/`max_length:`/`pattern:` for strings, `enum:` for any type, `properties:`/`required:` for `:json` |
| `validate:` | optional callable — the escape hatch for rules a schema cannot express |
| `variants:` | optional — the dial's variant dimensions (see below) |
| `label:` / `unit:` / `description:` | metadata for the admin surface you build |

The constraints are deliberately not a bespoke vocabulary: they are **JSON
Schema keywords**, snake_cased for Ruby. If you've written `minimum` /
`maximum` / `enum` / `pattern` in a JSON Schema or an OpenAPI spec, you
already know this API — and because the constraints are the standard's, a
declaration can hand its rules to any JSON Schema tooling via
`definition.to_json_schema` (see the
[API Reference](/reference/api#constraints)).

A dial with no `variants:` is **global-only**: it can never hold per-scope
values, which is exactly what you want for a kill switch.

Declaring a dial generates its methods: `use_<key>` to read,
`adjust_<key>` to write, `clear_<key>` to remove an override. They are real
methods, defined at declaration time — `respond_to?`, tab completion, and
grep all work.

## Read

```ruby
Dials.use_signups_enabled                  # global-only dial: no scope
Dials.use_checkout_fee_bps(market: "KE")   # varied dial: scope required
```

The scope must name **every** dimension the dial declares — a missing or
unknown dimension raises `Dials::InvalidScope` immediately, in development,
not quietly in production.

Reads cost a hash lookup. No query runs per read — see [Caching](/concepts/caching).

## Write

```ruby
# Global override (applies wherever no variation exists):
Dials.adjust_checkout_fee_bps(300, actor: current_admin)

# Per-market variation:
Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")

# Remove overrides (each layer falls back to the one below):
Dials.clear_checkout_fee_bps(actor: current_admin, market: "BD")
Dials.clear_checkout_fee_bps(actor: current_admin)
```

`actor:` is required on every write — there is no anonymous mutation path.
(That is also why `actor` is a reserved dimension name.) Values are validated
against the declared type and schema before anything is stored.

## Dynamic access

When the dial key arrives at runtime — an admin surface iterating the
registry, a console one-liner — use the key-taking primitives that the
generated methods delegate to:

```ruby
Dials.get(:checkout_fee_bps, market: "KE")
Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: current_admin)
Dials.clear(:checkout_fee_bps, scope: { market: "BD" }, actor: current_admin)
```

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
- [Variants and Scopes](/concepts/variants-and-scopes) — dimensions, enums,
  and the exact-scope rule
- [Retrofit a Constant](/guides/retrofit-a-constant) — adopting dials in an
  existing app

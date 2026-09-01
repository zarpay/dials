---
layout: home
hero:
  name: dials
  text: Constants you can turn without a deploy
  tagline: Declare a value in code with a default, a type, and a schema. Override it at runtime. Vary it per market, per platform, per anything. Every change attributed, every read cached.
  actions:
    - theme: brand
      text: Start with Quick Start
      link: /getting-started/
    - theme: alt
      text: Learn the Concepts
      link: /concepts/the-dial-model
---

## The problem this gem solves

Every application accumulates values like these:

```ruby
CHECKOUT_FEE_BPS = 250
FREE_DELIVERY_THRESHOLD = 5_000
SIGNUPS_ENABLED = true
```

Then the arc begins. Someone needs to change a fee **today**, so the constant
becomes a database row with an admin form. Then a second market launches and
needs a *different* fee, so the row grows a country column and a sentinel
value for "global". Six months later the app has some values in specialized
domain tables, others in an app-wide settings table, and a home-brewed
resolver next to each one — every developer solving fallback, validation,
and caching again, slightly differently, with no shared answer to "who
changed this and what values are safe?"

Dials is that whole arc, designed once:

- **Declarations stay in code.** A dial's default, type, constraints, and
  variant dimensions are Ruby, reviewed in PRs — the database stores only
  overrides. Constraints speak JSON Schema (`minimum:`, `enum:`,
  `pattern:`, ...), so they're declarative data an admin surface can render.
- **Resolution is one rule.** `variation → global override → code default`,
  always. Delete every override and you are back to exactly what the code says.
- **Variants are first-class.** `variants: { market: { enum: %w[KE NG BD] } }`
  arms a dial for per-market values; the gem validates every scope against
  the declaration.
- **Every write is attributed.** `Dials.adjust_checkout_fee_bps(..., actor:
  current_admin)` is the only write path, and it appends to a change log you
  can render as history.
- **Reads are free.** A per-process snapshot cache serves every read from
  memory; a throttled probe (one cheap query per interval) converges other
  processes after a write.

## A five-minute example

```ruby
# config/initializers/dials.rb
Dials.define do
  dial :checkout_fee_bps, default: 250,
       type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
       variants: { market: { enum: %w[KE NG BD] } }

  dial :signups_enabled, default: true, type: :boolean,
       description: "Global kill switch for signups."
end
```

Each declaration generates the dial's methods — read with `use_`, write with
`adjust_`, remove an override with `clear_`:

```ruby
Dials.use_checkout_fee_bps(market: "KE")   # => 250   (code default)

Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")
Dials.use_checkout_fee_bps(market: "BD")   # => 120   (variation)
Dials.use_checkout_fee_bps(market: "KE")   # => 250   (still the default)

Dials.clear_checkout_fee_bps(actor: current_admin, market: "BD")
Dials.use_checkout_fee_bps(market: "BD")   # => 250   (back to code)

Dials.changes(key: :checkout_fee_bps)
# => [#<ChangeRecord action="clear" actor_label="keith@..." ...>, ...]
```

## The running example

The docs stay grounded in **Bazario**, a fictional commerce platform in three
markets (KE, NG, BD) across three platforms (ios, android, web). Bazario is a
real Rails app — the [`demo/`](https://github.com/zarpay/dials/tree/main/demo)
package in this repository — and its spec suite proves every claim these
pages make.

## What dials is not

Not a secrets manager, not deploy configuration, not a feature-flag system
with percentage rollouts, and not for per-market values that are deliberately
priced as bundles. The boundary matters; it has its own page:
[When NOT to Use a Dial](/concepts/pattern-boundary).

---
layout: home
hero:
  name: dials
  text: Constants you can turn without a deploy
  tagline: Declare a value in code with a default, a type, and bounds. Override it at runtime. Vary it per market, per platform, per anything. Every change attributed, every read cached.
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
needs a *different* fee, so the row grows a country column, a sentinel value
for "global", and a pile of special-case reads. Six months later nobody is
sure which values are real, who changed them, or what the safe range is.

Dials is that whole arc, designed once:

- **Declarations stay in code.** A dial's default, type, bounds, and variant
  dimensions are Ruby, reviewed in PRs — the database stores only overrides.
- **Resolution is one rule.** `variation → global override → code default`,
  always. Delete every override and you are back to exactly what the code says.
- **Variants are first-class.** `variants: { market: { options: %w[KE NG BD] } }`
  arms a dial for per-market values; the gem validates every scope against
  the declaration.
- **Every write is attributed.** `Dials.set(..., actor: current_admin)` is the
  only write path, and it appends to a change log you can render as history.
- **Reads are free.** A per-process snapshot cache serves every `Dials.get`
  from memory; a throttled probe (one cheap query per interval) converges
  other processes after a write.

## A five-minute example

```ruby
# config/initializers/dials.rb
Dials.define do
  dial :checkout_fee_bps, 250,
       type: :integer, bounds: 1..10_000, unit: "bps",
       variants: { market: { options: %w[KE NG BD] } }

  dial :signups_enabled, true, type: :boolean,
       description: "Global kill switch for signups."
end
```

```ruby
Dials.get(:checkout_fee_bps, market: "KE")   # => 250   (code default)

Dials.set(:checkout_fee_bps, 120, scope: { market: "BD" }, actor: current_admin)
Dials.get(:checkout_fee_bps, market: "BD")   # => 120   (variation)
Dials.get(:checkout_fee_bps, market: "KE")   # => 250   (still the default)

Dials.clear(:checkout_fee_bps, scope: { market: "BD" }, actor: current_admin)
Dials.get(:checkout_fee_bps, market: "BD")   # => 250   (back to code)

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

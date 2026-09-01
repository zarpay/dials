# Retrofit a Constant

The most common adoption path in an existing app: a class constant needs to
become operator-adjustable, usually because someone just asked for a change
that shouldn't need a deploy.

## Before

```ruby
class Checkout::FeeCalculator
  FEE_BPS = 250

  def fee_cents(subtotal_cents)
    (subtotal_cents * FEE_BPS) / 10_000
  end
end
```

## Step 1 — declare the dial with the constant's value as default

```ruby
# config/initializers/dials.rb
Dials.define do
  dial :checkout_fee_bps, default: 250,
       type: :integer,
       minimum: 1,
       maximum: 10_000,
       unit: "bps",
       description: "Fee charged on checkout, in basis points."
end
```

No `dimensions:` yet — this dial is global-only until something reads a varied
value ([the arming gate](/concepts/dimensions-and-scopes)).

Choose the constraints now, while you're thinking about it — `minimum:` and
`maximum:` are the difference between "operator typo'd 25000" being a
validation error and being an incident.

## Step 2 — replace the constant read

```ruby
class Checkout::FeeCalculator
  def fee_cents(subtotal_cents)
    (subtotal_cents * Dials.use_checkout_fee_bps) / 10_000
  end
end
```

Delete the constant. Don't keep it "for reference" — two sources of truth is
how the next engineer edits the dead one.

**This deploy changes nothing observable.** No override rows exist, so every
read resolves to the code default: the same 250 the constant held. That's the
core property of the retrofit — it's a pure refactor until an operator acts.

## Step 3 — vary it, when (and only when) needed

When the BD market needs a different fee, one PR does both halves:

```ruby
# The arming diff — visible in review:
dial :checkout_fee_bps, default: 250,
     type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
     dimensions: { market: { enum: %w[KE NG BD] } }
```

```ruby
# ...and the reader grows its scope in the same PR:
Dials.use_checkout_fee_bps(market: @market)
```

Note the read signature changed: a varied dial **requires** its scope. Every
call site must supply the market — the exact-scope rule turns "I forgot one
call site" into an immediate `InvalidScope`, not a silent global read.

Then the operator sets the value through your write surface (or console,
attributed):

```ruby
Dials.adjust_checkout_fee_bps(120, actor: "keith — BD launch", market: "BD")
```

## Tests

Anywhere a test previously stubbed the constant:

```ruby
stub_const("Checkout::FeeCalculator::FEE_BPS", 1_000)   # before
Dials::Testing.with_overrides(checkout_fee_bps: 1_000)  # after (and validated!)
```

`with_overrides` validates against the declaration, so a test can no longer
pin a value production could never hold.

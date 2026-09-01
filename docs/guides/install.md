# Install (New Apps)

The greenfield path: five minutes, three steps, no data migration.

## 1. Install and migrate

```bash
bundle add dials
bin/rails generate dials:install
bin/rails db:migrate
```

The generator creates:

- **One migration** for the three gem-owned tables — `dials`,
  `dial_variations`, `dial_changes`. All value columns are JSON **text**
  (portable across PostgreSQL, MySQL, and SQLite; nothing ever queries inside
  a value, so jsonb buys nothing — see [Caching](/concepts/caching)).
- **`config/initializers/dials.rb`** with a commented starter registry.

## 2. Configure and declare

```ruby
# config/initializers/dials.rb
require "dials/active_record"

Dials.configure do |config|
  config.store = :active_record
  config.cache_ttl = 5.0
  config.actor_label = ->(actor) { actor.email }
end

Dials.define do
  dial :checkout_fee_bps, default: 250,
       type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
       description: "Fee charged on checkout, in basis points.",
       variants: { market: { enum: %w[KE NG BD] } }
end
```

Declarations can be split across multiple `Dials.define` blocks (one per
domain) — they accumulate, and a duplicate key raises at boot.

A plain initializer is the right home: the registry holds only strings,
numbers, and lambdas, so it does not touch autoloaded constants and is safe
across code reloading. If a dimension's enum comes from an autoloaded
model, pass a callable — `enum: -> { Market.pluck(:code) }` — which is
resolved lazily, on first use.

## 3. Read where the constant would have been

```ruby
class Pricing::QuoteService
  def initialize(market:)
    @market = market
  end

  def fee_cents(subtotal_cents)
    (subtotal_cents * Dials.use_checkout_fee_bps(market: @market)) / 10_000
  end
end
```

Consumers never know which layer a value came from. That is the point.

## Recommended from day one

- **A registry-integrity spec** pinning your declared dials and which are
  armed for variation, so arming shows up in review as a failing pin — copy
  [`demo/spec/dials/registry_spec.rb`](https://github.com/zarpay/dials/blob/main/demo/spec/dials/registry_spec.rb).
- **The test-suite hygiene line** — see [Testing with Dials](/guides/testing).
- **A write surface** with your app's auth in front of the write path — see
  [Build a Write Surface](/guides/build-a-write-surface). Until you build
  one, `Dials.adjust_checkout_fee_bps(...)` from a console (with a real
  `actor:` string, e.g. your name) is a legitimate, fully-logged interim
  surface.

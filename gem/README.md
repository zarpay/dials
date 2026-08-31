# dials

Operator-adjustable values with per-variant overrides, attribution, and
caching.

You wrote a constant. Then you needed to change it without a deploy, so you
built an admin surface. Then you needed a different value per market. Dials is
that whole arc as one small library:

```ruby
# config/initializers/dials.rb
Dials.define do
  dial :merchant_fee_bps, 100,
       type: :integer, bounds: 1..10_000, unit: "bps",
       variants: { market: { options: %w[KE NG BD] } }

  dial :signups_enabled, true, type: :boolean,
       description: "Global kill switch for new signups."
end
```

```ruby
Dials.get(:merchant_fee_bps, market: "KE")   # => 100 (the code default)

Dials.set(:merchant_fee_bps, 90, scope: { market: "KE" }, actor: current_admin)
Dials.get(:merchant_fee_bps, market: "KE")   # => 90
Dials.get(:merchant_fee_bps, market: "NG")   # => 100

Dials.clear(:merchant_fee_bps, scope: { market: "KE" }, actor: current_admin)
Dials.get(:merchant_fee_bps, market: "KE")   # => 100 again

Dials.changes(key: :merchant_fee_bps)        # attributed, append-only history
```

Resolution is always **variation → global override → code default**. The
database stores only overrides; deleting them returns you to what the code
says. Reads come from a per-process cache with a throttled staleness probe,
so a dial read costs a hash lookup, not a query.

## Installation

```bash
bundle add dials
bin/rails generate dials:install   # migration (3 tables) + initializer
bin/rails db:migrate
```

Full documentation: <https://zarpay.github.io/dials/> — including the design
decisions, the caching model, retrofit guides for existing apps, and when a
value should *not* be a dial.

## Development

```bash
bundle install
bundle exec rake       # minitest + rubocop
```

The sibling `demo/` package in this repository is a Rails app whose test
suite exercises the entire public API against a real database.

## License

MIT.

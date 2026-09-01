# dials

Operator-adjustable values with per-scope overrides, attribution, and
caching.

You wrote a constant. Then you needed to change it without a deploy, so you
built an admin surface. Then you needed a different value per market. Dials is
that whole arc as one small library:

```ruby
# config/initializers/dials.rb
Dials.define do
  dial :merchant_fee_bps, default: 100,
       type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
       dimensions: { market: { enum: %w[KE NG BD] } }

  dial :signups_enabled, default: true, type: :boolean,
       description: "Global kill switch for new signups."
end
```

The constraint keywords are **JSON Schema**, snake_cased (`minimum:`,
`maximum:`, `enum:`, `pattern:`, `properties:`/`required:` for `:json`
values) — if you've written an OpenAPI spec or a JSON Schema, you already
know this vocabulary, and `definition.to_json_schema` hands the real
fragment to admin UIs and client-side validators.

Each declaration generates the dial's methods:

```ruby
Dials.use_merchant_fee_bps(market: "KE")   # => 100 (the code default)

Dials.adjust_merchant_fee_bps(90, actor: current_admin, market: "KE")
Dials.use_merchant_fee_bps(market: "KE")   # => 90
Dials.use_merchant_fee_bps(market: "NG")   # => 100

Dials.clear_merchant_fee_bps(actor: current_admin, market: "KE")
Dials.use_merchant_fee_bps(market: "KE")   # => 100 again

Dials.changes(key: :merchant_fee_bps)      # attributed, append-only history
```

The key-taking primitives (`Dials.get`, `Dials.set`, `Dials.clear`) stay
public underneath, for code that receives the key at runtime — an admin
surface iterating the registry, a console one-liner.

Resolution is always **scoped override → global override → code default**. The
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

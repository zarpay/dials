# dials

Constants you can turn without a deploy.

A dial is declared in code with a default and a type. Operators override it at
runtime; the override lives in **one append-only table**, is served from a
per-process cache, and carries the actor who made it. The declaration stays in
code review, where it belongs — the database only ever stores values.

```ruby
Dials.define do
  dial :checkout_fee_bps, default: 250, type: _Integer(1..10_000),
       unit: "bps", variants: { market: %w[KE NG BD] }
end

Dials.checkout_fee_bps                            # => #<Dials::Dial checkout_fee_bps ...>
Dials.checkout_fee_bps.for(market: "KE")          # => 250
Dials.checkout_fee_bps.set(120, market: "BD", actor: admin)
Dials.checkout_fee_bps.for(market: "BD")          # => 120
```

## Install

```ruby
gem "dials"
```

```sh
bin/rails generate dials:install
bin/rails db:migrate
```

That creates one table and one initializer. Declare your dials in the
initializer.

## Declaring

```ruby
Dials.define do
  dial :signups_enabled, default: true, type: _Boolean

  dial :checkout_fee_bps,
       default: 250,
       type: _Integer(1..10_000),
       unit: "bps",
       description: "Fee charged at checkout.",
       variants: { market: %w[KE NG BD], platform: %w[ios android] }
end
```

`default:` and `type:` are required; everything else is optional.

**A type is anything that answers `===`.** A class (`Integer`), a range
(`1..10`), a regexp, an Array of allowed values, a lambda — or one of
[Literal](https://github.com/joeldrapper/literal)'s types, which are in scope
inside the `define` block without importing anything:

```ruby
type: Integer                 # any integer
type: _Integer(1..10_000)     # an integer in a range
type: _Boolean                # true or false, and nothing else
type: %w[low normal high]     # one of these
type: _String(/\A[A-Z]{3}\z/) # a string matching a pattern
type: _JSONData               # any JSON-native structure
```

The default is validated against the type at declaration time, so a dial that
could never hold its own default fails at boot rather than in production.

`variants:` are the dimensions the dial may vary along, each declared with the
same kind of matcher. Declaring them is the arming gate: **a dial with no
variants is global-only by construction**, and adding one belongs in the same
change as the code that reads the varied value.

## Reading

```ruby
Dials.checkout_fee_bps.for(market: "KE")   # scoped read
Dials.signups_enabled.value                # global read

Dials[:checkout_fee_bps].for(market: "KE") # by key, for code handed one at runtime
Dials.all                                  # the whole catalog, for an admin screen
```

Every stored scope the request satisfies is a candidate; **the most specific one
wins**, and the code default is what you get when none match. The global
override is not a special case — it is simply the candidate that names no
dimensions, so it matches everything and loses to anything more specific.

```ruby
Dials.fee.set(300, actor: ops)                            # everywhere
Dials.fee.set(200, market: "BD", actor: ops)              # all of BD
Dials.fee.set(100, market: "BD", platform: "ios", actor: ops)

Dials.fee.for(market: "BD", platform: "ios")     # => 100
Dials.fee.for(market: "BD", platform: "android") # => 200
Dials.fee.for(market: "KE", platform: "ios")     # => 300
```

A scope naming a dimension the dial does not declare, or a value that dimension
does not allow, raises rather than quietly falling through to the global.

## Writing

```ruby
Dials.checkout_fee_bps.set(120, market: "BD", actor: current_admin)  # => 120
Dials.checkout_fee_bps.clear(market: "BD", actor: current_admin)     # => true
```

`actor:` is required on every write and lands in the change log. Pass a model
(its class, id, and email/name are recorded) or a plain string for a script.
Clearing returns resolution to the layer below: a cleared variant falls back to
the global, a cleared global to the code default. Clearing what was never set
writes nothing and returns `false`.

Values are validated on the way in, and are checked for surviving a JSON round
trip — so a symbol key or a `Time` is refused at write time rather than read
back as something else.

```ruby
Dials.checkout_fee_bps.cast(120)   # validate without writing, for a form
Dials.checkout_fee_bps.overrides   # => { {} => 300, {market: "BD"} => 120 }
Dials.checkout_fee_bps.history     # newest first, with actors
Dials.history                      # every dial
```

## The one table

Every set and every clear **inserts** a row. Nothing is ever updated or deleted.
The newest row for a `(key, scope)` pair is the current value, and a row with a
NULL value is a tombstone meaning "cleared".

| id | key | scope | value | actor_label |
|---|---|---|---|---|
| 3 | `checkout_fee_bps` | `{"market":"BD"}` | *NULL* | console |
| 2 | `checkout_fee_bps` | `{"market":"BD"}` | `120` | ops@example.com |
| 1 | `checkout_fee_bps` | `{}` | `300` | ops@example.com |

Append-only buys three things at once:

- **The change log is the state.** There is no second table to keep in step
  with the first.
- **Writers cannot conflict.** An INSERT has nothing to race for; the higher id
  wins, which is also the answer you want. There is no upsert, no unique
  violation to retry, no lock.
- **The row count is a version counter.** It moves on every write and never
  moves back, so one cheap query tells a process whether another process has
  written since it last looked.

## Caching

Reads come from a per-process snapshot of every override — one query, not one
per dial. It is rebuilt immediately when this process writes, and at most once
every `cache_ttl` seconds when the version check shows another process has.

```ruby
Dials.configure do |config|
  config.cache_ttl = 5.0        # 0 checks on every read
  config.actor_label = ->(actor) { actor.email }
end

Dials.reload!                   # give up the cache now
```

## Testing

```ruby
Dials.stub(checkout_fee_bps: 999) do
  Dials.checkout_fee_bps.for(market: "KE")  # => 999
end
```

Stubs are thread-local and never touch the database, the cache, or the history.
They are validated against the dial's type, so a test cannot pin a value
production could never hold — and they are applied *after* scope validation, so
a stub can never hide a scope bug.

If your suite rolls each example back in a transaction, call `Dials.reload!`
between examples so a rolled-back write cannot outlive its example in the cache.

## Development

```sh
bundle install
bundle exec rake     # minitest + rubocop
```

The suite runs against a real in-memory SQLite database, so it exercises the
actual table rather than a stand-in for it.

# Namespaces

A subsystem that needs an operator knob has two bad options. It can declare a
dial, and its override rows land in the host app's `dials` table, which the
host owns. Or it can build its own settings table, and give up types, bounds,
attribution, history, and stale-write protection.

A **namespace** is the third option: a dials instance of its own, with its own
registry, config, store, table, cache, change log, generated readers, and test
overrides.

```ruby
# in the engine's initializer
require "dials/active_record"

Shipping = Dials.namespace(:shipping, label: "Shipping") do |config|
  config.store = :active_record        # table: "shipping_dials"
end

Shipping.define do
  dial :max_parcel_kg, default: 20, type: :integer, minimum: 1, maximum: 50,
       unit: "kg", description: "Heaviest parcel a courier will accept."
end

Shipping.max_parcel_kg                              # => 20
Shipping.adjust_max_parcel_kg(30, actor: current_admin)
Shipping.changes                                    # this namespace's log only
```

What you do with `Dials` for the app's own dials, you do with the namespace
object: `define`, `configure`, `get`/`set`/`clear`, `overview`, `changes`,
`scoped_overrides`, `reload!`, `with_overrides`, and the three generated
methods per dial. Declaring and listing namespaces stays on the module
(`Dials.namespace`, `Dials.namespaces`, `Dials.default`).

## Install one

There is no generator flag for this. A namespace needs one table and a few
lines in an initializer, so write both.

The table is the same shape as the root's — copy
`create_dials_table` from `rails g dials:install` (or from
[Install](/guides/install)) and name it `shipping_dials`:

```ruby
create_table :shipping_dials do |t|
  # ... exactly the columns and indexes of the dials table
end
```

Then declare the namespace in `config/initializers/dials_shipping.rb`, as in
the example above. Load order does not matter: an engine can declare its
namespace before the app configures `Dials`, and options it does not set
still follow the root.

Declare namespaces and configure `Dials` during boot. Reconfiguring while
the app serves traffic is unsupported: a store swap or a `cache_ttl` change
propagates to child namespaces and their caches without a lock, so a read or
a write running at the same moment may see either side of it. Nothing in the
gem defends that, deliberately — see
[Design Decisions](/design/decisions).

A name is segments of lowercase letters and digits, each starting with a
letter, joined by single underscores (`bank_transfer`, `tier2`, not
`tier_2`). It becomes a table name and a model class name, and that rule is
what keeps both one-to-one with the namespace. Anything else raises
`Dials::InvalidNamespace`.

`config.table_name` renames the table. It is lowercase letters, digits and
underscores, at most 63 characters, and no two namespaces may resolve to one
table. Either raises `Dials::InvalidTableName` at boot.

## What a namespace owns

- **Its registry.** A key is unique inside its namespace. Two namespaces can
  both declare `:timeout_seconds`, with different types and different
  defaults.
- **Its table** — `<name>_dials`, unless `config.table_name` says otherwise.
  Two namespaces never share a table, so no reader has to filter on a
  namespace column.
- **Its change log**, because the rows are the log.
- **Its cache.** A write in one namespace busts one cache. No other namespace
  re-reads.
- **Its thread-local state.** A write inside an open transaction, and a
  `with_overrides` pin, apply to the namespace that made them. A test pin on
  one namespace does not change what another returns.
- **Its resolution.** A dial resolves inside its namespace: scoped override →
  global override → code default. There is no fallback into another namespace.

## What it takes from the app

- **Options it does not set.** `cache_ttl`, `actor_label` and `default_actor`
  read through to the root's config. An engine that sets nothing but its store
  still uses the app's probe interval and its attribution.
- **The store kind, not the store.** A namespace with no store of its own uses
  the kind the root uses, against its own table. A store *object* is never
  inherited: two namespaces on one store would share its rows. Under a custom
  store, a namespace names its own.

## The root namespace

`Dials` is the default namespace, named `:default`. Every method on the module
reads and writes through it, so an app that never mentions namespaces has
exactly one, and nothing changes for it. `Dials.default` names it explicitly.

`config.table_name_prefix` names the root's table (`"ops_"` → `ops_dials`).
Every other namespace names its table with `config.table_name`; the prefix
raises `Dials::Error` there.

## Finding namespaces

```ruby
Dials.namespaces             # every namespace, root first, then declaration order
Dials.namespace(:shipping)   # fetch one; raises UnknownNamespace
```

An admin page groups dials by walking `Dials.namespaces` and reading each
one's `label` and `overview`, without naming a subsystem:

```ruby
Dials.namespaces.map { |ns| [ns.label, ns.overview.dials] }
```

## When not to declare one

A namespace is for a subsystem that owns the setting: an engine, a bounded
context, something that could become its own service with the same
declarations. It is not a way to group one app's dials — a dial's
`description` and your admin page's own sections do that. Splitting one app's
dials across tables costs a migration and buys nothing.

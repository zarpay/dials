# Namespaces

A subsystem that wants an operator knob has two bad options. It declares a
dial, and its override rows land in the host app's `dials` table, which the
host owns. Or it builds its own settings table and gives up everything a
dial provides: types, bounds, attribution, a change log, stale-write
protection.

A **namespace** is the third option. It is a full dials instance — its own
registry, config, store, table, cache, change log, generated readers and
test overrides. The subsystem owns its settings end to end.

```ruby
# in the engine's initializer
require "dials/active_record"

BankTransfer = Dials.namespace(:bank_transfer, label: "Bank Transfer") do |config|
  config.store = :active_record        # table: "bank_transfer_dials"
end

BankTransfer.define do
  dial :min_transfer_usd, default: 5, type: :integer, minimum: 1, maximum: 10_000
end

BankTransfer.min_transfer_usd                              # => 5
BankTransfer.adjust_min_transfer_usd(6, actor: current_admin)
BankTransfer.changes                                       # this namespace's log only
```

Everything you do with `Dials` for the app's own dials, you do with the
namespace object: `define`, `configure`, `get`/`set`/`clear`, `overview`,
`changes`, `scoped_overrides`, `reload!`, `with_overrides`, and the three
generated methods per dial. Declaring and listing namespaces stays on the
module (`Dials.namespace`, `Dials.namespaces`, `Dials.default`).

## Install one

```bash
bin/rails generate dials:install --namespace=bank_transfer
```

That writes a migration for `bank_transfer_dials` and
`config/initializers/dials_bank_transfer.rb` declaring the namespace.

A name is lowercase letters, digits and single underscores — it becomes a
table name and a model class name, and that rule keeps both unique per
namespace. Anything else raises `Dials::InvalidNamespace`.

## What is separate, and what is shared

Separate, by construction:

- **The registry.** A key is unique inside its namespace. Two namespaces may
  both declare `:timeout_seconds`, with different types and different
  defaults.
- **The table.** A namespace owns a table — `<name>_dials` unless
  `config.table_name` says otherwise. Rows never mix, and no namespace
  column has to be trusted.
- **The change log**, because the rows are the log.
- **The cache.** A write in one namespace busts one cache. Nothing else
  re-reads.
- **Thread-local state.** A write inside an open transaction, and a
  `with_overrides` pin, apply to the namespace that made them. One
  namespace's test pin never changes how another resolves.
- **Resolution.** A dial resolves inside its namespace only:
  scoped override → global override → code default, and never a fallback
  into another namespace.

Shared, because an app configures it once:

- **Unset config options.** `cache_ttl`, `actor_label` and `default_actor`
  read through to the root's config when the namespace declares none of its
  own. An engine that configures nothing but its store still honours the
  app's probe interval and attribution.
- **`config.store` inherits by kind, never by object.** A namespace that
  declares no store gets the same *kind* the root uses — with a table of its
  own, because a namespace owns its rows. A store *object* is not
  inheritable (sharing one would put two namespaces in one key space): under
  a custom store, a namespace names its own.

## The root namespace

`Dials` itself is the default namespace, named `:default`. Every method on
the module delegates to it, so an app that never mentions namespaces has
exactly one and nothing changes. `Dials.default` names it explicitly.

`config.table_name_prefix` still names the root's table (`"zar_"` →
`zar_dials`). Every other namespace names its table with
`config.table_name`; setting the prefix on one raises `Dials::Error`, which
says so.

## Discovering namespaces

```ruby
Dials.namespaces          # every namespace, root first, then registration order
Dials.namespace(:bank_transfer)  # fetch one; raises UnknownNamespace
```

An admin surface groups dials by iterating `Dials.namespaces` and reading
each one's `label` and `overview` — without naming any subsystem:

```ruby
Dials.namespaces.map { |ns| [ns.label, ns.overview.dials] }
```

## When a namespace is the wrong answer

A namespace is for a subsystem that **owns** the setting — an engine, a
bounded context, something that could plausibly become its own service with
the same declarations. It is not a grouping mechanism for one app's dials:
that is what a dial's `description`, and your own admin page's sections,
are for. Splitting one app's dials across tables buys nothing and costs a
migration.

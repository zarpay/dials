# The Dial Model

## Three layers, one rule

Every read resolves through the same three layers, top down:

```
1. variation        — a stored value for exactly this scope   (dial_variations)
2. global override  — a stored value for everywhere else      (dials)
3. code default     — the value declared in Dials.define      (your initializer)
```

The first layer that has a value wins. That is the entire model; everything
else in the gem exists to keep this rule honest.

## The database stores only overrides

This is the load-bearing decision. When you declare

```ruby
dial :checkout_fee_bps, 250, type: :integer, bounds: 1..10_000
```

**no row is written anywhere**. The default lives in code, under code review,
in git history. A `dials` row appears only when an operator overrides the
global; a `dial_variations` row appears only when an operator overrides a
specific scope. Clearing an override deletes the row and resolution falls
back to the layer below.

Why not seed a row per dial at boot (`find_or_create`) and treat the row as
the value?

- **Changed defaults would silently do nothing.** With seeded rows, editing
  the default in code has no effect once the row exists — the row always
  wins, forever, even when nobody ever meant to override it. With override
  semantics, a changed default flows out on deploy *unless* someone
  deliberately overrode it — and an admin surface can show exactly which
  dials are overridden and offer "reset to default".
- **Boot-time writes are a tax.** Seeding at boot needs `table_exists?`
  guards for fresh clones and `rake db:migrate`, race handling across
  multi-process boot, and read-replica awareness. Override semantics write
  nothing until a human acts.
- **"No rows" means "nothing overridden".** The table is a worklist of
  deliberate operator decisions, not a mirror of the registry.

## The two-table shape

Variations are rows with a real `NOT NULL` foreign key to their parent:

```
dials            (key UNIQUE, value)            -- value NULL = no global override
dial_variations  (dial_id FK NOT NULL, scope, value)  -- UNIQUE (dial_id, scope)
```

Two alternatives were rejected, deliberately (full reasoning in
[Design Decisions](/design/decisions)):

- **Sibling rows related by a shared key string** (a `market` column on one
  table with an `'XX'` sentinel row for "global"): the relationship between a
  global and its variations becomes a naming convention rather than a
  constraint, every reader must know the sentinel, and "no variation without
  a global" is unenforceable.
- **Self-referential `parent_id` rows in one table**: carries the FK
  guarantee but makes every present and future reader responsible for
  filtering child rows — one forgotten `WHERE parent_id IS NULL` and a
  country's value is served globally.

With the separate table, the FK makes "no variation without a parent" a
database constraint, and there is no sentinel because **the parent is the
global**.

One subtlety: `dials.value` is nullable. If a dial has variations but no
global override (or its global override is cleared while variations exist),
the parent row survives with `value NULL` purely as the FK anchor. When the
last override of any kind is cleared, the parent row is removed too — "no
overrides" and "no rows" stay synonyms.

## `false` is a value

The gem's validation never confuses "no value" with `false`:

- `Dials.set(:signups_enabled, false, actor: ...)` stores JSON `false`.
- SQL `NULL` is reserved for "no override".
- `nil` is not a storable value for any type — removing an override is
  `Dials.clear`, so a stored nil could only ever be an accident, and the gem
  rejects it.

This sounds obvious. It is also the single most common way settings systems
break: a presence validation that rejects `false` makes a kill switch
impossible to turn off. The rule is pinned by tests at every layer of this
gem, including the HTTP layer of the demo app (Rails'
`params.require(:value)` rejects `false` too — see
[Build a Write Surface](/guides/build-a-write-surface)).

## Declarations are validated at boot

A `dial` declaration whose default violates its own type or bounds raises
`Dials::InvalidDefinition` when the initializer runs — the app fails to
boot. A dial that can be declared can be trusted: whatever resolution
returns, it satisfies the declared type and bounds, because both writes and
defaults pass the same validation.

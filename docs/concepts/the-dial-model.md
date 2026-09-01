# The Dial Model

## Three layers, one rule

Every read resolves through the same three layers, top down:

```
1. scoped override  — a stored override for exactly this scope
2. global override  — a stored override for everywhere else
3. code default     — the value declared in Dials.define (your initializer)
```

The first layer that has a value wins. That is the entire model; everything
else in the gem exists to keep this rule honest.

## The database stores only overrides

This is the load-bearing decision. When you declare

```ruby
dial :checkout_fee_bps, default: 250, type: :integer, minimum: 1, maximum: 10_000
```

**no row is written anywhere**. The default lives in code, under code review,
in git history. A row appears in the `dials` table only when an operator
stores an override — global or scoped. Clearing an override deletes the row
and resolution falls back to the layer below. "No overrides" and "no rows"
are synonyms, at every layer.

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

## One table of overrides

Every stored override is one row in one table, identified by its natural key:

```
dials        (key, scope, value NOT NULL, version)   -- UNIQUE (key, scope)
             -- scope "{}"          = the global override (the empty scope)
             -- scope {"market":..} = a scoped override
             -- version             = per-override stale-write stamp
dial_changes (append-only history; also the cache's version counter)
```

A global override **is** an override at the empty scope — the resolution
model already says so ("most specific scope wins; the global constrains
nothing"), and storage now says the same thing. `"{}"` is not a sentinel: it
is `Scope.canonical({})`, the truthful canonical encoding of a real value in
the scope algebra — unlike an `'XX'` pretending to be a market.

This shape has two structural payoffs:

- **`value` is NOT NULL.** "No override" is "no row" — there is no
  NULL-anchor state, no parent-row lifecycle to bookkeep, and the
  false-vs-NULL kill-switch hazard is excluded by the schema itself, not
  just by validation.
- **Concurrency needs no lock table.** Every row carries a `version` stamp,
  writes are guarded statements (`UPDATE/DELETE ... WHERE version = ?`), and
  the unique index is the guard for inserts — the database's own row
  semantics make each write, and
  [stale-write protection](/reference/api#expected-version-stale-write-protection),
  atomic against every concurrent write.

An earlier iteration used two tables (a parent `dials` row per key, with
scoped rows hanging off a foreign key). Why it changed — and why the original
choice was right in the system this pattern came from — is recorded honestly
in [Design Decisions](/design/decisions).

## `false` is a value

The gem's validation never confuses "no value" with `false`:

- `Dials.adjust_signups_enabled(false, actor: ...)` stores JSON `false`.
- SQL `NULL` is reserved for "no override".
- `nil` is not a storable value for any type — removing an override is
  `clear_signups_enabled`, so a stored nil could only ever be an accident,
  and the gem rejects it.

This sounds obvious. It is also the single most common way settings systems
break: a presence validation that rejects `false` makes a kill switch
impossible to turn off. The rule is pinned by tests at every layer of this
gem, including the HTTP layer of the demo app (Rails'
`params.require(:value)` rejects `false` too — see
[Build a Write Surface](/guides/build-a-write-surface)).

## Declarations are validated at boot

A `dial` declaration whose default violates its own type or schema raises
`Dials::InvalidDefinition` when the initializer runs — the app fails to
boot. A dial that can be declared can be trusted: whatever resolution
returns, it satisfies the declared type and schema, because both writes and
defaults pass the same validation.

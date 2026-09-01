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
in git history. Rows appear in the `dials` table only when an operator acts
— and since the table is append-only, clearing an override appends its own
attributed row rather than deleting anything; resolution falls back to the
layer below while the history of how it got there is preserved.

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

## One append-only table

The gem owns ONE table, and nothing in it is ever updated or deleted:

```
dials   (key, scope, seq, action, value, actor..., created_at)
        -- UNIQUE (key, scope, seq)
        -- one row per WRITE; the newest row per (key, scope) is current
        -- action "set"   = the override's value at that moment
        -- action "clear" = the override ended here
        -- scope "{}"     = the global override (the empty scope)
```

Every write INSERTs a row. The rows are simultaneously the current state
(newest per stream wins), the attributed history (`Dials.changes` walks the
same rows — an override's previous value is literally its previous row, so
history cannot disagree with what happened), and the cache's version
counter (the row count).

A global override **is** an override at the empty scope — the resolution
model already says so ("most specific scope wins; the global constrains
nothing"), and storage says the same thing. `"{}"` is not a sentinel: it is
`Scope.canonical({})`, the truthful canonical encoding of a real value in
the scope algebra — unlike an `'XX'` pretending to be a market.

Concurrency needs no lock table and no guarded updates: `seq` numbers each
stream's rows, and `UNIQUE(key, scope, seq)` means every writer claims the
stream's next slot — of two concurrent writes, the database rejects one.
That single mechanism is also what makes
[stale-write protection](/reference/api#expected-version-stale-write-protection)
atomic against every concurrent write.

Earlier iterations used two mutable tables, then one. Why the shape kept
simplifying — and why the original choice was right in the system this
pattern came from — is recorded honestly in
[Design Decisions](/design/decisions), with credit to the PR that proposed
the append-only form.

## `false` is a value

The gem's validation never confuses "no value" with `false`:

- `Dials.adjust_signups_enabled(false, actor: ...)` stores JSON `false`.
- "No override" is an explicit `clear` row (or no rows at all) — never an
  ambiguous NULL value.
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

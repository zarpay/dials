# Retrofit an Admin Table

The second adoption path: your app already has a home-grown version — a
`settings` / `system_configs`-style table with an admin form — and it's
straining (no types, no constraints, no dimensions, sentinel rows, unclear
history). This guide migrates values *out* of that table into dials.

Before starting, sort each row in the legacy table into one of three buckets:

## Bucket 1 — dial-shaped values

Flow-through semantics, one value, operator-owned. These migrate.

**Step 1 — declare, with the code default = today's production value.**

```ruby
dial :graduation_window_hours, default: 24,   # ← what production serves today
     type: :integer, minimum: 0, maximum: 8_760,
     description: "Hours before a waitlisted signup auto-graduates."
```

If today's production value is a sensible permanent default, that's the whole
data story — no data migration at all. If instead the code default should be
something *else* (the legacy value was an experiment), declare the default
you want and write today's value as an explicit override in a data migration:

```ruby
class MigrateGraduationWindowToDials < ActiveRecord::Migration[8.1]
  def up
    legacy = execute("SELECT value FROM legacy_settings WHERE key = 'graduation_window'")
    value = Integer(legacy.first["value"])
    Dials.adjust_graduation_window_hours(value, actor: "migration #{self.class.name}") if value != 24
  end
end
```

A dial write in a migration is fine: it validates, attributes ("who" is the
migration), and logs — the change log's first entry documents the handover.

**Step 2 — repoint readers.** Replace every read of the legacy row with
`Dials.graduation_window_hours`. Grep is your friend; the legacy key
string is usually distinctive.

**Step 3 — freeze, then drop.** Make the legacy row read-only in the old
admin (or delete it) the moment readers are repointed. Two writable sources
of truth is an incident generator. Drop the row (and eventually the table)
once nothing reads it.

## Bucket 2 — values that were already varying by sentinel

The classic shape: a `country` column where `'XX'` (or `NULL`, or `'global'`)
means "everyone else". These are dials with dimensions, and the migration
untangles the sentinel:

```ruby
# The sentinel row becomes the global; real countries become scoped overrides.
dial :graduation_window_hours, default: 24, type: :integer, minimum: 0, maximum: 8_760,
     dimensions: { market: { enum: MARKETS } }
```

```ruby
def up
  rows = execute("SELECT country, value FROM legacy_settings WHERE key = 'graduation_window'")
  rows.each do |row|
    if row["country"] == "XX"
      Dials.adjust_graduation_window_hours(Integer(row["value"]), actor: "migration")
    else
      Dials.adjust_graduation_window_hours(Integer(row["value"]),
                                           actor: "migration", market: row["country"])
    end
  end
end
```

The sentinel does not survive: after migration, the global lives on the
parent and every market row is a real scoped override, uniquely keyed.
Verify with a before/after read matrix in the migration or a one-off spec —
every (key, country) the legacy table answered must resolve identically
through the dial read.

## Bucket 3 — everything else

Rows that fail the dial test — bundles with snapshot semantics, secrets,
per-entity data, deploy config — **stay out**. Read
[When NOT to Use a Dial](/concepts/pattern-boundary) before migrating
anything; the rows that don't fit are not a gap in dials, they're a boundary
working as intended.

## Sequencing for zero downtime

Each value migrates independently — there is no big-bang cutover. The safe
per-value order is: declare (deploy; nothing changes) → data-migrate
overrides if any (still nothing reads them) → repoint readers (deploy; dials
now serve exactly the legacy values) → freeze legacy. At every step, a
rollback is "point the readers back".

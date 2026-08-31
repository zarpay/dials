# Design Decisions

Dials was extracted from a production fintech backend, where the pattern
went through eight design revisions and six adversarial review rounds before
this gem generalized it. These are the decisions that survived, and why.

## Declarations in code, values in the database

The registry (keys, types, bounds, dimensions, labels) is Ruby in an
initializer; the database stores only override values. Consequences we
wanted: dial changes to *what can be configured* go through code review and
git history; dial changes to *values* go through the attributed runtime
path. A database-defined registry would make "what are the bounds of this
dial?" a runtime question with no reviewer, and bounds-as-data can't hold a
lambda.

## Overrides, not seeds

The alternative — `find_or_create` a row per dial at boot, row is the value —
was the original sketch and was rejected. With seeded rows, editing a
default in code silently does nothing once the row exists; "reset to
default" has no meaning; boot-time writes need table-existence guards, race
handling, and replica awareness. With override semantics, the code default
is live until someone deliberately acts, the UI can distinguish "default"
from "overridden", and clearing an override is a delete, not a guess at what
the default used to be. Full argument in
[The Dial Model](/concepts/the-dial-model).

## Two tables, real foreign key, no sentinels

Per-scope values are rows in `dial_variations` with a `NOT NULL` FK to
`dials`, unique on `(dial_id, scope)`. This shape won over two alternatives
that were each tried or seriously examined in the original system:

- **A scope column on one table with a sentinel row** (`'XX'` = global). The
  original design's first draft. Rows related only by a shared key string
  are the weak form of the idea: "no variation without a global" is
  unenforceable, every reader must know the sentinel, and the sentinel
  leaks into validation ("XX is not a country, except here").
- **Self-referential `parent_id`.** Carries the FK but poisons every reader:
  any query that doesn't filter children can serve one scope's value
  globally. In the originating system, a cache that did
  `pluck(:key, :value).to_h` would have collapsed duplicate keys and served
  one country's value to the world — the redesign made that shape
  *inexpressible* rather than merely guarded.

With the separate table, the parent **is** the global, so reading the parent
table stays safe by construction.

One nullable column carries the model's only subtlety: `dials.value` is NULL
when variations exist but no global override does (the row is then just the
FK anchor). `NULL` = "no override" and JSON `false` = "false" are distinct by
construction, which is what makes kill switches turn-off-able — a lesson
the originating system learned when a `presence: true` validation nearly
shipped an un-clearable kill switch.

## The change log is a table the gem owns, and it is also the clock

Attribution ships in-gem (`dial_changes`) rather than as a PaperTrail
integration: history of operator changes is the product here, not an audit
add-on, and a hard dependency on a versioning gem would be the tail wagging
the dog. The log doubles as the cache's version counter (max id), which
means the freshness mechanism watches *exactly* the writes the gem performs
— an elegant fit that also defines the escape hatch's cost: writes bypassing
the gem are invisible to the probe and need `Dials.reload!`.

## Exact scopes now, partial scopes designed-for

Multi-dimension dials raise the precedence question (does `{market: KE}`
beat `{platform: ios}`?). v1 refuses to make operators learn a precedence
table: a variation names every declared dimension, and either matches
exactly or the global serves. But the resolver already implements the
general rule (subset match, most-specific wins, ties by declared dimension
order), the canonical-scope storage already represents partials, and the
gem's tests already pin the partial behavior — so enabling partials later
is deleting a write-side restriction, not a migration. See
[Variants and Scopes](/concepts/variants-and-scopes).

## Scope-in-one-column (JSON text), not one column per dimension

Because dimensions are **per-dial**, columnar storage means nullable columns
for the union of every dial's dimensions, migrations on gem-owned tables
whenever any dial adds a dimension, and unique-index gymnastics (SQL `NULL`s
are distinct, so `UNIQUE (dial_id, market, platform)` admits duplicates
without PG15's `NULLS NOT DISTINCT`). And the payoff would be queryability
that nothing needs: reads come from the in-process snapshot, so the database
is durable storage, not a query surface. Canonical JSON strings in one
column give exact uniqueness, portability, and zero-migration dimension
growth. The same reasoning makes all value columns JSON *text* rather than
jsonb.

## No bundled GUI

The original system's dashboard was a bespoke Rails controller with CAS
(compare-and-swap) writes, confirm modals, and inherit-vs-override cells —
deeply coupled to that app's auth, permissions, and taste. A gem GUI would
either fight every host app's admin stack or be a lowest-common-denominator
table. The gem ships the contract instead (registry introspection, typed
writes, attribution, history) and documents the surface pattern:
[Build a Write Surface](/guides/build-a-write-surface). A GUI may become a
separate opt-in engine later; it will not grow inside the core.

## `actor:` is explicit, required, and unguessed

No `Current.user` discovery, no default. The write surface knows who is
acting; the gem should not guess and must not allow anonymous writes. A
console write is `actor: "keith — BD launch"` — string actors are
first-class because attributed console operations beat unattributed ones.

## The arming gate is the declaration itself

The originating system carried a `country_writable:` flag flipped in the
same PR as each dial's reader, pinned by a spec — protecting against
configure-before-consume (a stored value nothing reads yet, waiting to
surprise whoever ships the reader). The gem keeps the invariant and deletes
the flag: declaring `variants:` is the gate, and the recommended
registry-integrity spec makes arming a visible diff. Global-only dials fall
out for free: no declaration, no variations, no flag.

## Errors, not fallbacks, at the boundaries

Unknown dial, missing dimension, unknown dimension, out-of-options value,
out-of-bounds write, nil value, missing actor — all raise typed errors
immediately. The only silent path is the happy one (no override → next layer
down). A configuration system that guesses at what you meant is a
configuration system you cannot trust during an incident.

# Design Decisions

Dials was extracted from a production fintech backend, where the pattern
went through eight design revisions and six adversarial review rounds before
this gem generalized it. These are the decisions that survived, and why.

## Declarations in code, values in the database

The registry (keys, types, constraints, dimensions, labels) is Ruby in an
initializer; the database stores only override values. Consequences we
wanted: dial changes to *what can be configured* go through code review and
git history; dial changes to *values* go through the attributed runtime
path. A database-defined registry would make "what may this dial hold?" a
runtime question with no reviewer, and constraints-as-database-rows can't hold a
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

## One table of overrides — a reversed decision, recorded honestly

Storage is one table, and (see the next section) it is append-only: every
override is a stream of rows keyed by `(key, scope)`, where the global
override is the stream at the **empty scope**, stored as its canonical
encoding `"{}"`.

An earlier iteration of this gem used two tables (a parent `dials` row per
key, `dial_variations` hanging off a `NOT NULL` FK), inheriting the shape
from the originating system, where it was the **right** choice: that app had
many pieces of code querying the tables directly, and the two-table shape
made "serve one country's value to the world" inexpressible for every
present and future reader (a `parent_id` single table had nearly shipped
exactly that bug via a careless `pluck(:key, :value).to_h`). It also
rejected an `'XX'` sentinel row — a lie inside the dimension's value space
that every reader had to know.

Both of those arguments quietly lost their force in the gem, and an
adversarial review (Claude proposing, Codex attacking) confirmed it from the
code:

- **There is exactly one reader and one writer — the store.** Every other
  access goes through the in-process snapshot. A shape that exists to
  protect many direct readers protects readers that cannot exist here.
- **`"{}"` is not a sentinel.** It is `Scope.canonical({})` — the truthful
  canonical encoding of a real value in the scope algebra. The `'XX'`
  objection does not transfer.
- **The FK invariant enforced less than it advertised.** It guaranteed a
  scoped row had a parent *row*, not a parent *override* (scoped overrides
  legitimately outlive a cleared global) — a mechanical anchor whose
  lifecycle (create-on-first-variation, destroy-with-last-override, the
  `InvalidForeignKey` retry case) was pure bookkeeping cost.
- **The nullable `dials.value` was the model's one standing subtlety.**
  Unified, a "set" row always carries a value, so NULL-vs-false can no
  longer be confused anywhere — a clear is an explicit event row, never an
  ambiguous NULL state.
- **The planned partial-scopes future lands on this shape.** Under
  "most-specific scope wins", the global is literally the empty partial
  scope; the unified table makes storage match the resolution model exactly.

Two cautions the review attached, kept deliberately visible: uniqueness on
`(key, scope)` is textual under the column collation (canonical encoding
makes gem writes safe; MySQL's case-insensitive defaults mean dimension
options shouldn't differ only by case), and the composite index carries
explicit column limits (key 100, scope 255) to stay inside every supported
database's index budget.

## The log is the state (and also the clock)

The table is **append-only**: every write INSERTs one row, and the newest
row per `(key, scope)` stream is the current override — action `set`
carries a value, action `clear` ends the override. This came out of PR #1
(Stephen's minimal-implementation exploration), adopted here with one
addition that closes its race: `seq` numbers each stream's rows under
`UNIQUE(key, scope, seq)`, so every writer claims the stream's next slot
and of two concurrent claims the database rejects one. What the shape buys:

- **History cannot disagree with state** — they are the same rows. An
  override's previous value is literally its previous row, so
  `Dials.changes` *derives* old values instead of trusting a second copy.
- **Nothing mutates or deletes.** No upserts, no guarded UPDATE/DELETE, no
  lifecycle bookkeeping; a clear appends its own attributed row.
- **Point-in-time reconstruction is available** ("config as of last
  Tuesday" = rows where created_at ≤ T, newest seq wins) — a capability the
  mutable design couldn't offer cheaply.
- The table grows only at human write rates — the same posture the change
  log always had ("grows slowly forever; don't prune it").

One advertised property changed shape: "no override = no row" became "no
override = the stream's newest row is a clear (or the stream never
existed)". Deliberate: the rows a clear leaves behind ARE the history.

Attribution still ships in-gem rather than as a PaperTrail integration:
history of operator changes is the product here, not an audit add-on. The
same rows double as the cache's version counter (count + max id), which
means the freshness mechanism watches *exactly* the writes the gem performs
— and defines the escape hatch's cost: writes bypassing the gem are
invisible to the probe and need `Dials.reload!`.

## Exact scopes now, partial scopes designed-for

Multi-dimension dials raise the precedence question (does `{market: KE}`
beat `{platform: ios}`?). v1 refuses to make operators learn a precedence
table: a scoped override names every declared dimension, and either matches
exactly or the global serves. But the resolver already implements the
general rule (subset match, most-specific wins, ties by declared dimension
order), the canonical-scope storage already represents partials, and the
gem's tests already pin the partial behavior — so enabling partials later
is deleting a write-side restriction, not a migration. See
[Dimensions and Scopes](/concepts/dimensions-and-scopes).

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

## Generated per-dial methods: a bare reader, verb-carrying writers

The primary API is generated at declaration time: `Dials.base_fee(...)` to
read, `Dials.adjust_base_fee(...)` and `Dials.clear_base_fee(...)` to write.
This naming took three tries, each recorded. First, generated methods were
rejected outright because a bare `Dials.store_amount` reads like a write
when it is a read. Second, uniform `use_`/`adjust_`/`clear_` prefixes
resolved that by giving every name a verb. Third (adopted from PR #1's
exploration), the reader dropped its prefix: reading is what you do with a
dial all day and pays no prefix tax, while the writers keep their verbs — so
a bare name is always a read and a mutation always announces itself. The
original objection stays answered: nothing bare can write.

The bare reader costs one thing: a dial cannot share a name with a facade
method (`:store`, `:cache`, `:changes`, ...) — the boot-time collision check
turns that into an `InvalidDefinition` error rather than silent shadowing.

Three properties keep the dynamic layer honest:

- The methods are **defined at declaration time**, never `method_missing` —
  `respond_to?`, tab completion, and a grep for `base_fee` all work, and
  a name collision raises `InvalidDefinition` at boot.
- The key-taking primitives (`Dials.get` / `set` / `clear`) **stay public**
  as the dynamic-access layer, because a write surface receives the key as a
  request param and cannot name a method statically.
- Scope travels as bare keywords on the generated forms, so **`actor` is a
  reserved dimension name** — on a write it must always mean attribution.

## Constraints speak JSON Schema

Value constraints use JSON Schema's keyword vocabulary, snake_cased for Ruby
(`minimum:`, `maximum:`, `enum:`, `pattern:`, `properties:`/`required:`), in
place of an earlier bespoke `bounds:` slot (Range / Array / callable). Three
reasons, in order of weight:

- **Constraints become data, not code.** A callable bound is a black box: an
  admin surface can render nothing from `#<Proc>`, and its failure message is
  generic. Named keywords render as UI affordances, produce specific error
  messages, and serialize — `Definition#to_json_schema` hands any client-side
  validator (or an agent reading the catalog) the real rules.
- **Extension is pre-decided.** The next constraint someone needs already has
  a name with settled semantics in the standard. Borrowing the vocabulary
  wholesale means no bespoke naming decisions as the API grows, and the words
  are already familiar to humans and agents alike.
- **The value model already was JSON.** Dial types map onto JSON Schema types
  (`:float` → `number`), and every stored value round-trips through JSON by
  design — the constraint language now matches the value language.

Two deliberate divergences from the standard, both toward boot-time
strictness: keywords are validated against the dial's type at declaration
(JSON Schema silently ignores keywords on mismatched types — exactly the
silent-nothing this gem's boot checks exist to prevent), and declaring
`properties:`/`required:` pins a `:json` dial's values to objects. A
`validate:` callable remains as the explicitly non-serializable escape hatch,
and dimension `options:` became `enum:` so the whole declaration speaks one
vocabulary.

PR #1 later proposed replacing this vocabulary (and the `validate:` escape
hatch) with case-equality objects and a hard dependency on the Literal gem.
Declined: constraints-as-data is the point — a standard, serializable
vocabulary that admin surfaces and agents can read — and the core stays
zero-dependency.

## One vocabulary: dimensions and overrides

Early iterations used three near-synonyms: `variants:` declared a dial's
axes, `Dimension` was the class those axes became, and "variation" named a
stored scoped value. The declaration keyword and the docs needed the words
to define each other ("`variants:` — the dial's variant dimensions"), and
"variant" collides with the experimentation industry's meaning, where a
variant is one of the candidate *values* (control/treatment) — the opposite
end of the idea from an axis.

The vocabulary is now two words for two concepts: a **dimension** is an axis
a dial varies along (`dimensions:` in the declaration, matching the class
and the resolution language — a scope names dimensions, most-specific-wins
counts them), and an **override** is a stored value at a scope — *global*
(the empty scope) or *scoped*. "Variant" and "variation" survive only in
historical records (the changelog, this page's history, already-run demo
migrations); *vary* as a plain verb remains ordinary English.

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

No `Current.user` discovery. The write surface knows who is acting; the gem
should not guess. A console write is `actor: "keith — BD launch"` — string
actors are first-class because attributed console operations beat
unattributed ones.

One relaxation, for apps with no user identity at all: an app may *declare*
a fallback (`config.default_actor`, a value or per-write callable) in its
initializer, making `actor:` optional. That preserves the decision's core —
the gem never discovers an actor on its own; the fallback is a reviewed,
deliberate line of configuration, an explicit `actor:` always wins, and
with no fallback declared the requirement stands unchanged. What was NOT
built: a no-logging mode — the change log is also the cache's version
counter and the CAS comparison target, so silencing it would break
convergence and stale-write protection (see
[Possible Enhancements](/design/possible-enhancements)).

## The arming gate is the declaration itself

The originating system carried a `country_writable:` flag flipped in the
same PR as each dial's reader, pinned by a spec — protecting against
configure-before-consume (a stored value nothing reads yet, waiting to
surprise whoever ships the reader). The gem keeps the invariant and deletes
the flag: declaring `dimensions:` is the gate, and the recommended
registry-integrity spec makes arming a visible diff. Global-only dials fall
out for free: no declaration, no scoped overrides, no flag.

## Stale-write protection is per-override optimistic locking

`expected_version:` compares against the version of the **override being
written** — the global's, or the named scoped override's, with
`Dials::ABSENT_VERSION` asserting "no override was stored here when I
looked". The token is the stream's live `seq`; rows are immutable and seq
only grows, so a token can never be revisited (a cleared-and-recreated
override continues its stream). Atomicity is the seq claim under
`UNIQUE(key, scope, seq)`: an interleaving writer (conditional or not)
takes the slot, the loser's INSERT is rejected by the database, and the
re-run re-reads and raises StaleWrite. No lock table, no advisory locks, no
guarded updates — and nothing has to opt in for CAS to hold.

This is the fourth shape this feature has had, and the path is worth
recording. v1 compared a whole-store version and serialized only CAS writers
on a lock-row anchor; an adversarial review (Codex) caught that unconditional
writes could slip inside the check-to-commit window, so v2 made every write
take the anchor lock. Then the "why does an insert need a lock at all?"
question (Keith's) exposed the root: the lock existed only because the
compare target was an *aggregate*, which no conditional statement can guard.
v3 moved the compare target into the row (guarded UPDATE/DELETE), deleting
the `dial_locks` table and the whole-store design's false conflicts. v4
(with the append-only storage from PR #1) replaced the guarded statements
with the seq claim — same guarantee, one mechanism for inserts, updates,
and clears alike. PR #1 itself proposed shipping WITHOUT atomicity (an
advisory check, honestly labeled); that was declined: its author's own
analysis showed that adding atomicity back converges on this design, and a
race that "basically never happens" is still a race.

Two commitments carried through every shape: `StaleWrite` is deliberately
excluded from the store's retry loop (a retried CAS would recompute against
the new version and succeed, silently defeating the mechanism), and a stale
no-op clear still refuses — a page showing an override that no longer exists
is stale. The table's count+max(id) remains the **cache probe's** clock; it
was only ever the wrong thing to CAS against.

A second adversarial review (Codex, against the shipped v4) hardened the
edges: tombstones keep their stamp so ABSENT strictly means "never written"
(closing an absent → set → clear ABA that had existed, unnoticed, since v3);
CAS tokens are minted from the write itself rather than a follow-up read a
concurrent writer could front-run; a lost seq claim converts directly to
StaleWrite (a lost claim proves an interleaver — correct even inside an
aborted outer transaction); the cache keeps a last-known-good snapshot
across busts so a database blip right after a write degrades reads instead
of raising; MySQL identity columns get a binary collation in the migration;
quarantine covers unknown actions and noncanonical scopes; and dial keys
must be callable identifiers. A third verification pass then caught the one
regression the fixes themselves introduced — tombstone scopes skipped
validation, so a corrupt clear row could crash `Dials.overview` — and
aligned history's quarantine rules with state's, so the two views can never
disagree about which rows are valid.

## Validation happens at write time, not read time

Type and schema are enforced when a value is stored (and on every code
default at boot). Already-stored values are **not** re-validated on read:
if a deploy narrows a dial's schema from `maximum: 1000` to `maximum: 100`, a stored
`900` keeps serving until an operator changes it. This is deliberate.
Read-time enforcement has no good failure mode — rejecting the stored value
mid-request means either raising (an incident caused by a deploy that
changed no values) or silently substituting the default (exactly the kind
of guess this gem refuses to make). The honest contract: narrowing a
declaration is a migration, and the deploy that narrows a schema should check
`Dials.changes` / the stored overrides for now-invalid values and fix
them explicitly. What read-time *does* defend is robustness, not policy:
rows corrupted around the gem are quarantined with a warning rather than
taking down every dial read.

## Errors, not fallbacks, at the boundaries

Unknown dial, missing dimension, unknown dimension, out-of-enum value,
schema-violating write, nil value, missing actor — all raise typed errors
immediately. The only silent path is the happy one (no override → next layer
down). A configuration system that guesses at what you meant is a
configuration system you cannot trust during an incident.

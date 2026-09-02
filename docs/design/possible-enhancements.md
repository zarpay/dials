# Possible Enhancements

Things the gem deliberately does **not** do yet. Each was considered, and in
most cases the design already accommodates it — what's missing is a real
need. This page exists so those ideas don't have to be re-derived
later: if you hit one of these needs, the groundwork and the
open questions are recorded here.

None of this is a commitment. The gem stays small until a concrete use case
forces a decision.

## Partial scopes

**The idea.** A dial declares `dimensions: { market: ..., platform: ... }` and
an operator writes an override for `{ market: "KE" }` alone — meaning "KE,
every platform" — instead of one row per platform.

**What already exists.** More than you'd expect: the resolver already
implements the general matching rule (a stored scope matches when every pair
it names appears in the request; most dimensions named wins; ties break by
the dial's declared dimension order), the canonical-scope storage represents
partial scopes today, and the gem's test suite pins the partial-scope
resolution behavior. Shipping this is deleting the `exact: true` restriction
on the **write** path, plus admin-surface affordances.

**Why it waits.** Precedence is a concept operators must hold in their
heads — "which override wins here and why" stops being a one-sentence
answer. Until a dial exists whose scope fan-out is genuinely painful
(writing 3 platform rows to cover one market is not painful; 40 locales ×
6 platforms would be), the simpler mental model wins.

## An explicit global read (`Dials.global`)

**The idea.** On a varied dial, the bare `Dials.<key>` reader without scope raises by
design — a scopeless read is usually a context-threading shortcut that
silently serves the wrong value once scoped overrides exist (see
[Dimensions and Scopes](/concepts/dimensions-and-scopes)). But there may be
legitimate "give me the fallback layer" reads: an ops dashboard showing the
default, a report about the configuration itself. `Dials.global(:key)` would
answer *global override → code default*, deliberately ignoring scoped
overrides —
explicit, greppable, reviewable, while accidental omission stays an error.

**Why it waits.** It's unclear anyone wants the global *as a value* rather
than as a fact about configuration — and the registry plus
`Dials.changes` already answer the "what is configured?" questions. Adding
it early would hand context-threading shortcuts a blessed-looking escape
hatch. If you find yourself fabricating a scope (`market: "KE"` because
it's first in the list) just to get a number, that's the signal this is
needed — say so before working around it.

## An opt-in admin engine

**The idea.** A mountable Rails engine rendering the registry: inherit
vs. override cells per scope, confirm-before-write with old → new values,
the change log as a timeline. v1 ships [the contract and the
pattern](/guides/build-a-write-surface) instead, because every team's admin
stack already has auth and styling that a bundled GUI would fight.

**Why it waits.** The first two or three hand-built surfaces will reveal
what's actually common across them. An engine extracted from real surfaces
beats one designed in advance — and it would live as a separate opt-in
package (`dials-admin`), never in the core gem.

## Disabling the change log

**The idea.** A mode for apps that want dials without history.

**Why it never will happen.** The log is the state: the append-only table's
rows ARE the current overrides, the history, and the cache's version
counter, so "dials without history" is not a mode the storage could offer —
deleting history would delete the state.
The usual motivations don't hold up anyway: attribution never needed a
User model (string actors; `config.default_actor` makes `actor:` optional),
a PII concern is answered by `config.default_actor = "anonymous"`, and at
operator write-rates the table stays small forever. An app that wants no
record of operator changes should not use this gem.

## Point-in-time reads (`as_of:`)

**The idea.** "What was the config when the incident started?" — resolve
against the store as it was at time T, or render a whole overview `as_of:` a
timestamp.

**What already exists.** Everything: storage is append-only, so the state at
time T is exactly "rows with created_at ≤ T, newest seq per stream wins".

**Why it waits.** No surface has asked for it yet. When one does, the open
questions are API shape (a scoped `Dials.as_of(time) { ... }` block vs.
`overview(as_of:)`) and whether time-travel reads bypass the cache (they
should — they're rare, investigative, and never hot-path).

## Non-ActiveRecord stores

**The idea.** The store interface is small and documented
(`Stores::Memory` is the executable spec), so a Redis or HTTP-backed store
is a straightforward contribution.

**Why it waits.** The staleness probe's version counter, the transactional
write+log guarantee, and the `expected_version:` compare-and-swap contract
all lean on the database today. A new store must provide all three, and no
concrete deployment has asked for one.

---

Have a need that belongs here, or a concrete case for one of these? Open an
issue — the bar isn't "would this be nice" but "here is the concrete
situation the current design handles badly."

# Possible Enhancements

Things the gem deliberately does **not** do yet. Each was considered, and in
most cases the design already accommodates it — what's missing is a real
need. This page exists so those ideas don't have to be re-derived (or
re-litigated) later: if you hit one of these needs, the groundwork and the
open questions are recorded here.

None of this is a commitment. The gem's bias is to stay small until a
concrete use case forces a decision, because speculative surface area is how
configuration systems get weird.

## Partial scopes

**The idea.** A dial declares `variants: { market: ..., platform: ... }` and
an operator writes a variation for `{ market: "KE" }` alone — meaning "KE,
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

**The idea.** On a varied dial, `Dials.use_<key>` without scope raises by
design — a scopeless read is usually a context-threading shortcut that
silently serves the wrong value once variations exist (see
[Variants and Scopes](/concepts/variants-and-scopes)). But there may be
legitimate "give me the fallback layer" reads: an ops dashboard showing the
default, a report about the configuration itself. `Dials.global(:key)` would
answer *global override → code default*, deliberately ignoring variations —
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

## Stale-write protection (compare-and-swap)

**The idea.** Two operators open the same dial; both edit; the second write
silently clobbers the first. A CAS-style write —
`Dials.adjust_<key>(..., expect: <the value or change-id the operator saw>)` —
would reject the second write with a "value changed under you" error for
the surface to render.

**What already exists.** The change log gives any surface the data to
detect and display this after the fact; the loss window is small at
operator scale (humans, low write rates).

**Why it waits.** It's a write-surface concern more than a storage concern,
and the right shape (expected old value? expected last change id?) should be
chosen by the first surface that actually needs it. The originating system's
dashboard implemented CAS on row identity and it earned its keep — so this
is likely the first item on this page to graduate.

## Non-ActiveRecord stores

**The idea.** The store interface is small and documented
(`Stores::Memory` is the executable spec), so a Redis or HTTP-backed store
is a straightforward contribution.

**Why it waits.** The staleness probe's version counter and the
transactional write+log guarantee lean on the database today. A new store
must provide both, and no concrete deployment has asked for one.

---

Have a need that belongs here, or one of these needs graduating? Open an
issue — the bar isn't "would this be nice" but "here is the concrete
situation the current design handles badly."

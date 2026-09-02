# When NOT to Use a Dial

Dials has a sharp boundary, and using it on the wrong side produces subtle
production incidents rather than error messages. The test:

> A value is a dial when the global default **should flow through** to every
> scope that hasn't explicitly overridden it.

That flow-through is what makes a dial useful — and what makes it dangerous
on the wrong value — so check each candidate against the cases below.

## Dial-shaped values

- A checkout fee that is 250bps everywhere, except two negotiated markets.
- A delivery threshold tuned per market as data comes in.
- A kill switch.
- A batch size, a timeout, a retry count that ops adjusts under load.

The common trait: when someone updates the global, you **want** every non-overridden
scope to move with it, immediately.

## Deliberately-priced bundles are NOT dials

Suppose each market's merchant pricing is negotiated: the fee, the partner's
revenue share, and the settlement terms are decided **together, per market**,
by a human looking at that market. Two properties disqualify it:

1. **Flow-through is wrong.** If the "default" fee changes, a negotiated
   market must NOT silently move. Snapshot semantics — full-copy rows per
   market — are the intent, not a smell to refactor away.
2. **The columns are a bundle.** Fee, share, and terms are one decision; a
   dial holds one value. Modeling a bundle as N independent dials invites
   changing one leg of a negotiated package in isolation.

Keep these as plain domain tables. If you're unsure which case you have, ask
the operational question: *"when the default changes, should priced markets
move?"* If anyone says "no, obviously not" — domain table.

## Not configuration, not secrets, not flags

- **Deploy configuration** (database URLs, API endpoints, per-environment
  tuning) belongs in ENV / credentials — it changes with deploys and differs
  by environment, not by operator decision.
  [ultra_settings](https://github.com/bdurand/ultra_settings) is the good
  tool for that layering.
- **Secrets** never belong in a dial. The change log stores old and new
  values in plaintext by design.
- **Feature flags** overlap at the edges (a boolean dial is a fine kill
  switch), but percentage rollouts, actor targeting, and A/B experiments are
  a different problem — use [Flipper](https://github.com/flippercloud/flipper)
  when you need *those*.
- **High-cardinality per-entity values** (a price per SKU, a limit per user)
  are domain data. Dials scopes are for small enumerable dimensions —
  markets, platforms, locales — a table an operator can read, not a
  million-row store.

## Rule of thumb

If the value's natural home is a spreadsheet an operator owns, it's probably
a dial. If its natural home is a migration, a contract, or a vault — it
isn't.

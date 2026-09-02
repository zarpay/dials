# Changelog

## [Unreleased]

- **Stale-write hardening (second adversarial review).** Cleared overrides
  keep a tombstone token, so `Dials::ABSENT_VERSION` strictly means "never
  written" and an old absent assertion goes stale when set/clear activity
  happened since (closes an ABA present since the guarded-row design); a CAS
  clear returns the tombstone's token (chainable). CAS tokens are minted
  from the write itself — store write methods return `[result, stamp]` —
  never from a follow-up read a concurrent writer could front-run. A lost
  seq claim on a CAS write converts directly to `StaleWrite`. The cache
  retains a last-known-good snapshot across busts, so a database blip right
  after a write serves slightly-stale data instead of raising. The install
  migration gives MySQL identity columns a binary collation. Quarantine now
  also catches unknown actions and noncanonical scopes; `changes` fetches
  predecessors with per-stream predicates; dial keys must be plain callable
  identifiers. A verification pass on the fixes closed the one regression
  they introduced (tombstone scopes skipped validation and a corrupt clear
  row could crash `Dials.overview`) and gave history the same quarantine
  rules as state.
- **Breaking: the log is the state — one append-only table.** Adopted from
  PR #1's minimal-implementation exploration (thanks @fractaledmind), with
  one addition that closes its acknowledged race: `seq` numbers each
  (key, scope) stream's rows under `UNIQUE(key, scope, seq)`, so every
  writer claims the stream's next slot and of two concurrent claims the
  database rejects one — stale-write protection stays atomic. Every write
  INSERTs exactly one row; the newest row per stream is the current
  override (`set` carries a value, `clear` ends it); state, attributed
  history, and the cache's version counter are the same rows, so history
  cannot disagree with state and `Dials.changes` derives old values from
  the previous row instead of trusting a stored copy. The `dial_changes`
  table is gone; stale-write tokens are stream seqs (immutable rows, so no
  token is ever revisited). PR #1's other proposals were declined
  deliberately: no new runtime dependencies (constraints stay JSON Schema,
  the memory store stays zero-dependency), and no advisory (non-atomic)
  version checks.
- **Breaking: readers are the bare dial name.** `Dials.checkout_fee_bps(
  market: "KE")` replaces `Dials.use_checkout_fee_bps(...)` — also from
  PR #1. Reading pays no prefix tax; the writers keep their verbs
  (`adjust_`/`clear_`), so a bare name is always a read. Consequence: a
  dial cannot share a name with a `Dials` method (`:store`, `:cache`, ...)
  — the existing boot-time collision check raises `InvalidDefinition`.
- **Breaking: one vocabulary — `dimensions:` and overrides; "variants" and
  "variation" retire.** The declaration keyword `variants:` is renamed
  `dimensions:` (it always declared dimensions — and "variant" collides with
  the experimentation-industry meaning, where a variant is a candidate
  VALUE, not an axis). `Definition#variants?` → `#dimensions?`;
  `Dials.variations(key)` → `Dials.scoped_overrides(key)`;
  `DialState#variations`/`#variation_versions` →
  `#scoped_overrides`/`#scoped_override_versions`. The store interface
  collapses to match the unified model: `set_override`/`clear_override`
  take a canonical scope (`Scope::GLOBAL` for the global), replacing
  `set_global`/`clear_global`/`set_variation`/`clear_variation`; the state
  hash's `variations` key becomes `scoped_overrides`. Prose now says
  "scoped override" wherever "variation" appeared; the docs page is
  "Dimensions and Scopes".
- **Breaking: stale-write tokens are per-override; the `dial_locks` table is
  gone.** `expected_version:` now compares against the override being
  written (the global's token, a variation's token, or
  `Dials::ABSENT_VERSION` for "no override was stored when I looked"),
  carried on `Dials.overview`'s DialStates as `global_version` and
  `variation_versions`. Each `dials` row carries a `version` stamp (the id
  of the change-log entry that last wrote it — store-monotonic, so
  delete-and-recreate can never revisit a version), and writes are the
  database's own atomic primitives: guarded `UPDATE`/`DELETE ... WHERE
  version = ?` plus the unique index for inserts. No lock table, no advisory
  locks, and the guarantee holds against every concurrent write without
  anyone opting in — while unrelated overrides can never false-conflict
  (the whole-store design refused a write because ANY dial had changed). CAS
  writes return the override's new token; a CAS clear returns
  `Dials::ABSENT_VERSION`. New `Dials::WriteConflict` covers the
  effectively-never case of unconditional writes outracing the store's
  retries. `Overview#version` remains as the informational store clock.
- **Breaking: one table of overrides.** The `dials` + `dial_variations` pair
  is replaced by a single `dials` table — one row per stored override, keyed
  by `(key, scope)` with the global stored as the canonical empty scope
  `"{}"` and `value` NOT NULL (no anchor rows, no NULL-vs-false ambiguity,
  "no override" = "no row" at every layer; internally the model is
  `Dials::ActiveRecord::Override`). The change log keeps NULL scope for
  global changes (history's stable encoding). Snapshot data now loads in one
  query; the version's two aggregates come from one statement. Explicit
  column limits (key 100 chars — now validated at declaration — and scope
  255) keep the composite unique index inside every supported database's
  budget. Regenerate the install migration; there is no data migration
  (pre-release).
- **`config.default_actor` — attribution without a User model.** Apps with
  no user identity can declare a fallback actor once (a string/object, or a
  callable evaluated per write, e.g. `-> { ENV.fetch("USER", "console") }`)
  and `actor:` becomes optional on every write path, including the generated
  writers. An explicit `actor:` always wins; with no fallback declared,
  writes without `actor:` raise `MissingActor` exactly as before. (String
  actors were always first-class — this only removes the per-write
  requirement for apps that declare their fallback.)
- **Enumeration API.** `Dials.variations(key)` returns one dial's stored
  variations keyed by parsed scope hashes ("which markets override this
  dial?"), and `Dials.overview` returns every registered dial's full state —
  definition (with its JSON Schema), explicit global-override
  presence/value, variations — read from one snapshot and stamped with a
  single opaque version token. Both read through the same path as the
  generated readers (in-transaction rule included) and return frozen
  structures.
- **Stale-write protection (compare-and-swap).** Every write path accepts
  `expected_version:` — an opaque token from `Dials.overview` (or a previous
  CAS write's return value). A mismatch raises the new `Dials::StaleWrite`
  with the write unapplied and nothing logged; the comparison is atomic with
  the write and deliberately never auto-retried. CAS writes return the new
  version token; unconditional writes keep their usual returns.
  `expected_version` joins `actor` as a reserved dimension name. (The token
  granularity and mechanism were refined in the same unreleased cycle — see
  the per-override entry above.)
- **Breaking: constraints now speak JSON Schema; `bounds:` is gone.**
  Declarations take the standard's keywords directly (snake_cased):
  `minimum:`/`maximum:`/`exclusive_minimum:`/`exclusive_maximum:`/
  `multiple_of:` for numbers, `min_length:`/`max_length:`/`pattern:` for
  strings, `enum:` for any type, and `properties:`/`required:` for `:json`
  objects (nested schemas support `items:` for arrays and must declare a
  `type:`). Keywords are checked against the dial's type at boot; declaring
  `properties:`/`required:` pins a `:json` dial to JSON objects. Dimension
  `options:` is renamed `enum:` (same vocabulary everywhere), `validate:` (a
  callable) replaces callable bounds as the escape hatch for rules a schema
  cannot express, and `Definition#to_json_schema` emits the declaration as a
  real JSON Schema fragment for admin surfaces and agents.
- **Breaking: `default:` is now a keyword argument in declarations.** The
  dial key is the only positional argument:
  `dial :checkout_fee_bps, default: 250, type: :integer, minimum: 1, maximum: 10_000`.
  The bare positional value was the one unlabeled thing in an otherwise
  fully-named declaration.
- **Generated per-dial methods are now the primary API.** Declaring
  `dial :base_fee, ...` defines `Dials.use_base_fee(**scope)`,
  `Dials.adjust_base_fee(value, actor:, **scope)`, and
  `Dials.clear_base_fee(actor:, **scope)` at declaration time (real methods,
  not `method_missing`). The key-taking primitives (`Dials.get` / `Dials.set`
  / `Dials.clear`) remain public as the dynamic-access layer for code that
  receives the key at runtime (admin surfaces, consoles). A declaration whose
  generated names collide with an existing method raises
  `InvalidDefinition`, and `actor` is now a reserved dimension name (on the
  generated writers it always means attribution, never scope).

Hardening from an adversarial (Codex) review of the 0.1.0 core:

- Cache version is now the change log's `[row count, max id]` — max id alone
  had a gap-commit hole where a transaction committing late with a lower id
  stayed invisible to warm processes.
- The cache never queries the store while holding a lock (connection-pool
  deadlock shape), stale refreshes are single-flight, and probe/rebuild
  failures serve last-known-good with a warning instead of raising (cold
  start still raises).
- A `Dials.set` inside an application database transaction no longer leaks
  uncommitted state into the shared cache; the writing thread reads its own
  uncommitted view via unpublished snapshots until the transaction closes.
- Corrupt rows (written around the gem) are quarantined with a warning at
  snapshot load instead of failing every dial read in the process.
- The memory store now JSON-round-trips values exactly like the ActiveRecord
  store: no retained references to caller-owned mutable objects, no
  store-dependent shape differences (symbol keys become strings everywhere).
- Declaration defaults are deep-frozen; resolution can no longer hand out a
  mutable reference to the code default.
- `:float` accepts only Integer/Float and rejects non-finite values;
  `:json` requires round-trip fidelity (symbol keys, Times, and arbitrary
  objects are rejected at write time instead of silently transforming).
- Malformed variant dimension specs (string `"options"` key, scalar specs,
  unknown keys) raise `InvalidDefinition` instead of silently creating an
  open dimension; open-dimension values are length-capped (128).
- Scopes naming the same dimension under two spellings raise instead of one
  value silently winning.
- ActiveRecord write retries now also cover `InvalidForeignKey` and
  `Deadlocked`/serialization failures, and never retry inside an outer
  application transaction; change rows are append-only through ActiveRecord
  (`readonly?`).
- `require "dials"` survives a broken Rails installation (railtie loading
  rescues more than `LoadError`); callable dimension options resolve once
  under a lock; core singletons initialize eagerly.

From the verification round (attacking the fixes themselves):

- A transactional write now also busts the cache ON COMMIT (via
  `ActiveRecord.after_all_transactions_commit` where available) — a
  mid-transaction republish of the pre-transaction state could otherwise
  outlive the commit when the writer never read again.
- A `bust!` that lands while a rebuild is in flight wins: the rebuild's
  snapshot (read before the write) is served to its requester but never
  published (generation counter).
- The probe timestamp is claimed before the version query, so readers
  crossing the TTL boundary together do not stampede the version check.
- Corrupt change-log rows are quarantined from `Dials.changes` like state
  rows; the memory store's retained change records are deep-frozen.
- Canonical scopes are capped at 255 bytes (the indexed VARCHAR) at
  validation time; a cyclic default raises `InvalidDefinition` instead of
  `SystemStackError` and never freezes the caller's object on failure.
- The generation check and snapshot publication now share a mutex (never
  held across store calls), closing the last republish window; the
  ActiveRecord adapter requires AR >= 7.2 at require time (the commit-time
  bust depends on `after_all_transactions_commit`; the :memory store works
  on any version); `Scope.parse` rejects stored scopes that are valid JSON
  but not objects, and change-row quarantine covers shape errors, not just
  parse errors.

## [0.1.0] - 2026-08-31

Initial release.

- Code-declared registry (`Dials.define` / `dial`) with types (boolean,
  integer, float, string, json), bounds (Range / Array / callable), labels,
  units, and descriptions.
- Variant dimensions per dial (`variants:`), validated options, exact-scope
  writes; resolution is variation → global override → code default with a
  most-specific-wins matcher already general enough for future partial
  scopes.
- Override semantics: the database stores overrides only; clearing an
  override returns resolution to the layer below.
- Per-process snapshot cache with throttled staleness probe (`cache_ttl`).
- Attributed writes: `Dials.set` / `Dials.clear` require `actor:`; every
  write lands in the append-only change log (`Dials.changes`).
- Stores: in-memory (default, zero-dependency) and ActiveRecord
  (`dials`, `dial_variations`, `dial_changes` tables; portable JSON-text
  columns).
- `rails g dials:install` generator (migration + initializer).
- `Dials::Testing.with_overrides` for client test suites.

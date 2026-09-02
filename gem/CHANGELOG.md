# Changelog

## [0.1.0] - 2026-09-02

Initial release.

- **Code-declared registry.** `Dials.define` with
  `dial :checkout_fee_bps, default: 250, type: :integer, minimum: 1, maximum: 10_000`
  — types (boolean, integer, float, string, json) plus labels, units, and
  descriptions. Constraints speak JSON Schema directly (snake_cased keywords:
  `minimum:`/`maximum:`/`exclusive_minimum:`/`exclusive_maximum:`/
  `multiple_of:` for numbers, `min_length:`/`max_length:`/`pattern:` for
  strings, `enum:` for any type, `properties:`/`required:` for `:json`
  objects), with `validate:` (a callable) as the escape hatch for rules a
  schema cannot express. `Definition#to_json_schema` emits each declaration
  as a real JSON Schema fragment for admin surfaces and agents.
- **Generated per-dial methods are the primary API.** Declaring a dial
  defines real methods at declaration time: readers are the bare dial name
  (`Dials.checkout_fee_bps(market: "KE")`), writers keep their verbs
  (`Dials.adjust_checkout_fee_bps(value, actor:, **scope)` and
  `Dials.clear_checkout_fee_bps(actor:, **scope)`), so a bare name is always
  a read. The key-taking primitives (`Dials.get` / `Dials.set` /
  `Dials.clear`) remain public as the dynamic-access layer for code that
  receives the key at runtime. Name collisions with existing `Dials` methods
  raise `InvalidDefinition`; `actor` and `expected_version` are reserved
  dimension names.
- **Dimensions and scoped overrides.** `dimensions:` declares a dial's axes
  (closed `enum:` option lists or open, length-capped values). The database
  stores overrides only; resolution is scoped override → global override →
  code default, with a most-specific-wins matcher. Clearing an override
  returns resolution to the layer below.
- **The log is the state — one append-only table.** Every write INSERTs
  exactly one row into a single `dials` table; the newest row per
  (key, scope) stream is the current override (`set` carries a value,
  `clear` ends it). Current state, attributed history (`Dials.changes`),
  and the cache's version counter are the same rows, so history can never
  disagree with state, and `changes` derives old values from the previous
  row instead of trusting a stored copy.
- **Stale-write protection (compare-and-swap).** Every write path accepts
  `expected_version:` — an opaque per-override token from `Dials.overview`
  or a previous CAS write's return value. Tokens are stream `seq` numbers
  claimed under `UNIQUE(key, scope, seq)`, so of two concurrent claims the
  database rejects one: the comparison is atomic with the write, holds
  against every concurrent writer without anyone opting in, and unrelated
  overrides can never false-conflict. A mismatch raises `Dials::StaleWrite`
  with the write unapplied and nothing logged, and is deliberately never
  auto-retried. Cleared overrides keep a tombstone token, so
  `Dials::ABSENT_VERSION` strictly means "never written" and absent
  assertions cannot be fooled by set-then-clear activity (no ABA).
- **Attributed writes.** Writers require `actor:` and every write lands in
  the append-only log. Apps without a user identity can declare
  `config.default_actor` (a value, or a callable evaluated per write) once;
  an explicit `actor:` always wins.
- **Enumeration API.** `Dials.overview` returns every registered dial's full
  state — definition (with its JSON Schema), global override, scoped
  overrides, and CAS tokens — from one snapshot stamped with a single
  version token; `Dials.scoped_overrides(key)` returns one dial's stored
  overrides keyed by parsed scope. Both read through the same path as the
  generated readers and return frozen structures.
- **Per-process snapshot cache** with a throttled staleness probe
  (`cache_ttl`), single-flight refreshes, and a last-known-good snapshot
  served (with a warning) when the store blips. Writes inside an application
  database transaction never leak uncommitted state into the shared cache —
  the writing thread reads its own view until commit, and the cache busts
  again on commit.
- **Hardened by adversarial review.** Corrupt rows written around the gem
  are quarantined with a warning instead of failing reads; values
  JSON-round-trip identically in both stores (no retained caller references,
  no store-dependent shapes); declaration defaults are deep-frozen; write
  retries cover deadlocks and serialization failures but never run inside an
  outer application transaction.
- **Stores:** in-memory (default, zero dependencies) and ActiveRecord
  (Rails/AR >= 7.2, portable JSON-text columns), with a
  `rails g dials:install` generator (migration + initializer).
- **`Dials::Testing.with_overrides`** for client test suites.
- **Zero runtime dependencies.**

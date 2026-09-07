# Changelog

## [Unreleased]

- **Namespaces.** A subsystem can own its dials:
  `Dials.namespace(:shipping) { |config| config.store = :active_record }`
  returns a dials instance of its own — its own registry, config, store,
  table (`shipping_dials`), cache, change log, generated readers and test
  overrides. A key is unique inside its namespace, so two namespaces may
  declare the same one, and a dial resolves inside its namespace only.
  `Dials.namespaces` lists every namespace (root first) for an admin surface
  that groups dials by subsystem, and `Dials.default` names the root.
  Unset options (`cache_ttl`, `actor_label`, `default_actor`) inherit the
  root's config; `store` inherits by kind, so an inheriting namespace still
  owns its table (a store *object* is not inheritable — sharing one would
  put two namespaces in one key space). `config.table_name` renames a namespace's table;
  `config.table_name_prefix` still names the root's.
- **Newly reserved dial keys.** A dial's reader must not shadow a method on
  its namespace, and the namespace object carries methods the `Dials` module
  did not: `label`, `with_overrides`, `default_label`, `root?`, `storage`,
  `txn_write_key`, `generated_module`, `install_generated!`,
  `uninstall_generated!`, `apply_cache_ttl`, `apply_store`,
  `inherit_cache_ttl`, `inherit_store`, `adopt`, `forget_children!` and
  `reset_config!` — plus the new module methods `default`, `namespace`,
  `namespaces`, `reload_all!` and `reset_namespaces!`. A dial declared under
  one of those names now raises `InvalidDefinition` at boot instead of at no
  point.
- A namespace name must be segments of lowercase letters and digits, each
  starting with a letter, joined by single underscores (`InvalidNamespace`
  otherwise): it becomes a table name and a model class name, and that rule
  keeps both one-to-one with the namespace. (`tier_2` is refused because it
  and `tier2` would derive the same model class, and the second namespace
  would silently repoint the first one's table.)
- **`Dials::InvalidTableName`.** A table name must be lowercase letters,
  digits and underscores, at most 63 characters — it reaches raw SQL
  unquoted, and PostgreSQL truncates identifiers past 63 bytes — and no two
  namespaces may resolve to one table. Both are checked at boot, on
  `config.table_name`, `config.table_name_prefix`, and the name a namespace
  derives from its own.
- Configuration is boot-time only, now stated as such in the docs: declare
  namespaces and configure `Dials` during boot, because reconfiguration
  concurrent with live traffic is unsupported.
- **`Dials.reload_all!`** reloads every namespace, and
  **`Dials.reset_namespaces!`** discards all but the root — for test suites.
- The `Dials` module is now the default namespace: `Dials.define`,
  `Dials.configure`, the generated readers, `Dials::Testing.with_overrides`,
  `Dials.reload!` and `Dials::ActiveRecord::Entry` behave exactly as before.
  Internals moved with the refactor, none of them documented API:
  `Dials::Testing::THREAD_KEY` and `Dials::Testing.override_for` are gone
  (each namespace keeps its own thread-local pins); `Dials::CACHE_LOCK` and
  `Stores::ActiveRecordStore::Entry` are gone (the store now takes
  `model:`); `Dials::ActiveRecord::Entry` subclasses a new abstract
  `Dials::ActiveRecord::Record`, and its `DEFAULT_TABLE_NAME` moved to the
  new `Dials::Storage`, which owns a namespace's store kind, table and
  model; `Dials::Actor.normalize`, `Registry.new` and `Config.new` now take
  the namespace (or its config and storage) they act for.

## [0.3.0] - 2026-09-07

- **`Dials.global(key)`.** Read a dial's Global layer by key: the stored
  global override when present, else the code default — the tail every
  un-overridden scope falls through to. The front door for callers with no
  scope to give (a subject whose dimension is unknowable), not a way around
  exact-scope reads: `get` still raises `InvalidScope` for a scopeless read
  of a dimensioned dial. Honors `Dials::Testing.with_overrides` pins; raises
  `UnknownDial`. Note: `global` joins the reserved `Dials` method names, so
  a dial named `:global` now fails at boot instead of being declarable.

## [0.2.0] - 2026-09-04

- **`config.table_name_prefix`.** Prefix the gem-owned table when `dials`
  collides with an existing table — `config.table_name_prefix = "zar_"`
  names it `zar_dials`. The prefix is used verbatim (trailing underscore
  included), mirroring Rails' `table_name_prefix` convention. The install
  generator takes the same prefix (`rails g dials:install
  --table-name-prefix=zar_`) so the migration and initializer match.

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

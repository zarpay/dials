# Changelog

## [Unreleased]

### 2.0.0.alpha — the minimal rewrite

A ground-up reimplementation of the same idea in roughly a fifth of the code.
Everything below is breaking.

- **One table instead of three.** `dials`, `dial_variations`, and
  `dial_changes` collapse into a single append-only `dials` table. Every
  adjustment and reset inserts a row; the newest row per `(key, scope)` is the
  current value, and a NULL value is a tombstone. The change log and the state are now
  the same thing, writers cannot conflict (there is no upsert to race), and the
  row count is the cache's version counter. The parent/child foreign key, the
  retry-on-`RecordNotUnique` logic, and the "destroy the orphaned parent" rule
  all cease to exist along with the second table.
- **One generated method per dial, and it returns the value.**

  ```ruby
  Dials.checkout_fee_bps(market: "KE")   # was Dials.use_checkout_fee_bps(market: "KE")
  Dials.checkout_fee_bps                 # the global value
  ```

  Never an object wrapping the value. Any object standing in for `false` is
  truthy, so a `Dial` returned here would make `if Dials.signups_enabled` run
  the guarded code with the switch turned off — silently, and with no way to
  fix it from inside the object, because Ruby has no falsy non-primitive.

- **Writes name the key: `Dials.adjust` and `Dials.reset`.**

  ```ruby
  Dials.adjust(:checkout_fee_bps, 120, market: "BD", actor: admin) # was Dials.adjust_checkout_fee_bps(...)
  Dials.reset(:checkout_fee_bps, market: "BD", actor: admin)       # was Dials.clear_checkout_fee_bps(...)
  ```

  Two methods instead of two per dial. The surfaces that write are holding a
  key already, so a generated writer would have been a second way to do what
  the admin form could not use anyway. `adjust` over `set` because a dial
  always has a value; you are moving it, not creating it.

- **`Dials[:key]` is the declaration**, for admin surfaces and consoles:
  `#label`, `#default`, `#type`, `#variants`, `#overrides`, `#history`, and
  `#cast` to validate a form input without writing it. `Dials.all` is the
  catalog. Getting an object is now something you type on purpose.
- **Types are `===`, via Literal.** `type:` and each variant dimension now take
  anything that answers `===`: a class, a range, a regexp, an Array of allowed
  values, or a [Literal](https://github.com/joeldrapper/literal) type
  (`_Integer(1..10_000)`, `_Boolean`, `_JSONData`), which are in scope inside
  the `define` block. This replaces the `:integer`/`:json` type symbols, the
  whole JSON-Schema constraint vocabulary (`minimum:`, `pattern:`,
  `properties:`, ...), `validate:`, and `Dimension`/`Schema` — about 300 lines
  of declaration machinery for one operator.
- **Resolution is one rule, not a three-layer ladder.** A stored scope matches
  when every pair it names is in the request; the most specific match wins.
  The global override is no longer a special case — it is the candidate that
  names no dimensions. Partial scopes now work on writes as well as reads:
  `set(150, platform: "ios")` covers every market.
- **ActiveRecord is the only store.** The pluggable store interface and the
  in-memory store are gone; the gem's own suite runs against real SQLite, so it
  exercises the table that ships.
- **`Dials.stub`** replaces `Dials::Testing.with_overrides`, and
  `Dials.undefine_all!` replaces `Dials.registry.reset!`.
- **Configuration is two accessors** — `cache_ttl` and `actor_label` — on
  `Dials` itself. The `Config` class, the `Railtie`, `Snapshot`, `Resolver`,
  `Registry`, `Actor`, `Freeze`, and `ChangeRecord` are all gone.

**Deliberately not carried over:** the single-flight/generation-counter guarding
around cache rebuilds (a concurrent rebuild may republish a snapshot up to
`cache_ttl` stale), corrupt-row quarantining (one row written around the gem now
raises on every read), and the thread-local in-transaction read isolation (a
rolled-back write can outlive its example in the cache unless the suite calls
`Dials.reload!`).

**Kept:** last-known-good serving. A read that cannot reach the database serves
the cached overrides with a warning rather than raising, and only raises when
there is no cache yet and so nothing honest to serve.

## Previous design

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

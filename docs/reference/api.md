# API Reference

## Declaration

### `Dials.define(&block)`

Runs the block against the registry. Blocks accumulate; a duplicate key
raises `Dials::DuplicateDial` at boot.

### `dial(key, default:, type:, bounds: nil, label: nil, unit: nil, description: nil, variants: nil)`

Declares one dial (inside a `define` block). Raises
`Dials::InvalidDefinition` at boot when the declaration is malformed, the
default fails its own type/bounds, or a generated method name is already
taken.

Each declaration generates the dial's three methods on `Dials`:
`use_<key>`, `adjust_<key>`, `clear_<key>` (see below). They are defined at
declaration time — real methods, not `method_missing`.

| Argument | Type | Notes |
|---|---|---|
| `key` | Symbol/String | unique across the app; the only positional argument |
| `default:` | value | the code default; validated like any stored value |
| `type:` | Symbol | `:boolean` `:integer` `:float` `:string` `:json` |
| `bounds:` | Range, Array, or callable | optional; callable returns truthy for storable |
| `label:` | String | defaults to the humanized key |
| `unit:` | String | display metadata (`"bps"`, `"cents"`, `"hours"`) |
| `description:` | String | shown on admin surfaces; write one |
| `variants:` | Hash or Array | variant dimensions; see below |

`variants:` shapes, all equivalent where applicable:

```ruby
variants: { market: { options: %w[KE NG BD] } }   # canonical
variants: { market: %w[KE NG BD] }                # shorthand: options array
variants: { market: -> { Market.pluck(:code) } }  # callable, resolved lazily
variants: { locale: {} }                          # open: any non-empty string
variants: [:market, :platform]                    # names only, all open
```

`actor` is a reserved dimension name — on the generated `adjust_`/`clear_`
methods it always means attribution, never scope.

## Reading

### `Dials.use_<key>(**scope) → value`

The generated reader:

```ruby
Dials.use_signups_enabled                  # global-only dial
Dials.use_checkout_fee_bps(market: "KE")   # varied dial
```

Resolves variation → global override → code default. Scope must name every
declared dimension exactly (values compared as strings). Raises
`Dials::InvalidScope`. Returned `:json` values are deep-frozen; hash keys
are strings.

### `Dials.get(key, **scope) → value`

The key-taking primitive under `use_<key>`, for code that receives the key
at runtime (an admin surface, a console). Same semantics; also raises
`Dials::UnknownDial` for an undeclared key.

### `Dials.registry`

Enumerable of `Dials::Definition`. Useful members for building UIs:

```ruby
Dials.registry.keys                 # [:checkout_fee_bps, ...]
Dials.registry.fetch(:key)          # Definition (raises UnknownDial)
Dials.registry.defined?(:key)       # true/false
definition.key .default .type .label .unit .description
definition.variants?                # any dimensions?
definition.dimension_names          # [:market, :platform]
definition.dimensions               # [Dimension(name, options), ...]
definition.problems_for(value)      # [] when storable, else messages
```

## Writing

### `Dials.adjust_<key>(value, actor:, **scope) → value`

The generated writer:

```ruby
Dials.adjust_checkout_fee_bps(300, actor: current_admin)                # global
Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")  # variation
```

Stores an override — global with no scope keywords, a variation with them.
Validates type, bounds, and scope; requires `actor:` (which is why `actor`
is a reserved dimension name). Appends to the change log and busts the local
cache. Raises `Dials::InvalidValue`, `Dials::InvalidScope`,
`Dials::MissingActor`.

### `Dials.clear_<key>(actor:, **scope) → true/false`

The generated remover. Removes an override; resolution falls to the next
layer down. Returns whether an override existed; clearing nothing is a
silent no-op (no log entry).

### `Dials.set(key, value, actor:, scope: nil)` / `Dials.clear(key, actor:, scope: nil)`

The key-taking primitives under `adjust_<key>` / `clear_<key>`, for dynamic
access. Scope travels as an explicit hash (`scope: { market: "BD" }`); both
also raise `Dials::UnknownDial` for an undeclared key.

### `Dials.changes(key: nil, limit: 50) → [ChangeRecord]`

Newest-first history. `ChangeRecord` is a Data class:
`key, scope, action ("set"/"clear"), old_value, new_value, actor_type,
actor_id, actor_label, created_at`, plus `#global?`.

## Configuration

```ruby
Dials.configure do |config|
  config.store = :active_record        # or :memory, or any store instance
  config.cache_ttl = 5.0               # seconds; 0 = probe every read; nil = never
  config.actor_label = ->(actor) { }   # change-log label builder
end
```

### `Dials.reload!`

Discard this process's snapshot; the next read rebuilds from the store.
Needed after writes that bypass the gem, and in test suites (see
[Testing](/guides/testing)).

## Testing

### `Dials::Testing.with_overrides(hash, &block)`

Thread-local, validated, nestable value pinning for the block's duration.
Applies to every scope of each pinned dial; never touches store, cache, or
log.

## Stores

A store is any object implementing the interface documented in
[`Dials::Stores::Memory`](https://github.com/zarpay/dials/blob/main/gem/lib/dials/stores/memory.rb)
(`state`, `version`, `set_global`, `clear_global`, `set_variation`,
`clear_variation`, `changes`). Shipped: `Stores::Memory` (default) and
`Stores::ActiveRecordStore` (via `require "dials/active_record"`).

## Generator

```bash
bin/rails generate dials:install
```

Creates the three-table migration and `config/initializers/dials.rb`.

## Errors

All inherit `Dials::Error`:

| Error | Raised when |
|---|---|
| `UnknownDial` | read/write of an undeclared key |
| `DuplicateDial` | a key declared twice |
| `InvalidDefinition` | malformed declaration (boot-time) |
| `InvalidValue` | wrong type, out of bounds, or nil on write/pin |
| `InvalidScope` | wrong/missing/unknown dimensions or values |
| `MissingActor` | write without `actor:` |

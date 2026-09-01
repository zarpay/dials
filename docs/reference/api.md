# API Reference

## Declaration

### `Dials.define(&block)`

Runs the block against the registry. Blocks accumulate; a duplicate key
raises `Dials::DuplicateDial` at boot.

### `dial(key, default:, type:, label: nil, unit: nil, description: nil, variants: nil, validate: nil, **constraints)`

Declares one dial (inside a `define` block). Raises
`Dials::InvalidDefinition` at boot when the declaration is malformed, a
constraint keyword doesn't apply to the type, the default fails its own
schema, or a generated method name is already taken.

Each declaration generates the dial's three methods on `Dials`:
`use_<key>`, `adjust_<key>`, `clear_<key>` (see below). They are defined at
declaration time — real methods, not `method_missing`.

| Argument | Type | Notes |
|---|---|---|
| `key` | Symbol/String | unique across the app; the only positional argument |
| `default:` | value | the code default; validated like any stored value |
| `type:` | Symbol | `:boolean` `:integer` `:float` `:string` `:json` |
| `label:` | String | defaults to the humanized key |
| `unit:` | String | display metadata (`"bps"`, `"cents"`, `"hours"`) |
| `description:` | String | shown on admin surfaces; write one |
| `variants:` | Hash or Array | variant dimensions; see below |
| `validate:` | callable | escape hatch for rules a schema cannot express; returns truthy for storable. Not serializable — prefer the schema keywords |
| *constraints* | keywords | value constraints in JSON Schema's vocabulary; see below |

### Constraints

Constraints are JSON Schema keywords, snake_cased for Ruby, passed directly
on `dial`. Each keyword is checked against the dial's type at boot — a
`pattern:` on an `:integer` dial raises `InvalidDefinition`, not nothing.

| Keyword | Applies to | Meaning |
|---|---|---|
| `enum:` | any type | non-empty Array of allowed values |
| `minimum:` / `maximum:` | `:integer` `:float` | inclusive bounds |
| `exclusive_minimum:` / `exclusive_maximum:` | `:integer` `:float` | exclusive bounds |
| `multiple_of:` | `:integer` `:float` | must divide the value exactly |
| `min_length:` / `max_length:` | `:string` | length in characters |
| `pattern:` | `:string` | Regexp (or String compiled to one); must match |
| `properties:` | `:json` | Hash of key => nested schema; see below |
| `required:` | `:json` | Array of keys that must be present |

```ruby
dial :checkout_fee_bps, default: 250, type: :integer, minimum: 1, maximum: 10_000
dial :tier, default: "low", type: :string, enum: %w[low medium high]
dial :support_email, default: "support@x.co", type: :string,
     pattern: URI::MailTo::EMAIL_REGEXP, max_length: 254
dial :welcome_banner, default: { "headline" => "Hi", "cta" => "Go" }, type: :json,
     properties: { "headline" => { type: :string, min_length: 1 },
                   "cta" => { type: :string } },
     required: %w[headline cta]
```

Nested schemas (inside `properties:`, and `items:` for arrays) must declare
a `type:` — one of `:boolean` `:integer` `:number` `:string` `:object`
`:array` (JSON Schema's own type names) — plus that type's keywords.
Declaring `properties:`/`required:` pins a `:json` dial's values to JSON
objects; keys not named in `properties:` are allowed.

`variants:` shapes, all equivalent where applicable:

```ruby
variants: { market: { enum: %w[KE NG BD] } }      # canonical
variants: { market: %w[KE NG BD] }                # shorthand: enum array
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

### `Dials.variations(key) → { scope => value }`

One dial's stored variations, keyed by **parsed** scope hashes (never
canonical scope strings) — "which markets have an override for this dial":

```ruby
Dials.variations(:checkout_fee_bps)   # => { { market: "BD" } => 120,
                                      #      { market: "NG" } => 180 }
```

`{}` when nothing is stored (or the dial declares no variants); raises
`Dials::UnknownDial` for undeclared keys. Reads through the same snapshot
path as every other read (in-transaction rule included); the result is
deep-frozen.

### `Dials.overview → Overview`

Every registered dial's full state — the `Definition` (with `json_schema`),
whether a global override exists and its value, and its variations — read
from ONE snapshot in one call, so an admin page renders a coherent picture
stamped with a single version:

```ruby
overview = Dials.overview
overview.version                    # opaque token; echo back as expected_version:
overview.dials.each do |state|
  state.key                         # :checkout_fee_bps
  state.definition                  # the Definition
  state.json_schema                 # JSON Schema fragment for this dial
  state.global_override?            # explicitly present-or-absent...
  state.global_value                # ...because false ≠ "no override"
  state.variations                  # { parsed scope => value }
end
```

All returned structures are frozen.

### `Dials.registry`

Enumerable of `Dials::Definition`. Useful members for building UIs:

```ruby
Dials.registry.keys                 # [:checkout_fee_bps, ...]
Dials.registry.fetch(:key)          # Definition (raises UnknownDial)
Dials.registry.defined?(:key)       # true/false
definition.key .default .type .label .unit .description
definition.variants?                # any dimensions?
definition.dimension_names          # [:market, :platform]
definition.dimensions               # [Dimension(name, enum), ...]
definition.problems_for(value)      # [] when storable, else messages
definition.to_json_schema           # JSON Schema fragment; see below
```

### `Definition#to_json_schema → Hash`

The declaration as a JSON Schema fragment — camelCase keywords, `pattern` as
its regexp source, `title`/`description`/`default` included — ready for a
client-side validator or an agent reading the dial catalog:

```ruby
Dials.registry.fetch(:checkout_fee_bps).to_json_schema
# => { "type" => "integer", "title" => "Checkout fee bps",
#      "minimum" => 1, "maximum" => 10_000, "default" => 250, ... }
```

A `validate:` callable is not representable and is simply absent from the
output; the server-side check still runs on every write.

## Writing

### `Dials.adjust_<key>(value, actor:, **scope) → value`

The generated writer:

```ruby
Dials.adjust_checkout_fee_bps(300, actor: current_admin)                # global
Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")  # variation
```

Stores an override — global with no scope keywords, a variation with them.
Validates type, schema, and scope; requires `actor:` (which is why `actor`
is a reserved dimension name). Appends to the change log and busts the local
cache. Raises `Dials::InvalidValue`, `Dials::InvalidScope`,
`Dials::MissingActor`.

### `expected_version:` — stale-write protection

Every write path (generated and primitive) accepts `expected_version:`,
which makes the write **compare-and-swap**: pass the token your page
rendered at (from `Dials.overview`) and the write is refused with
`Dials::StaleWrite` — unapplied, with nothing appended to the change log —
if the store has moved since. The comparison is atomic with the write:
every dial write (CAS or not) serializes on a single lock inside the
store's transaction, so a CAS write cannot interleave with ANY concurrent
gem write — of two writes carrying the same token, exactly one commits.

```ruby
overview = Dials.overview
# ... operator looks at the page, decides ...
token = Dials.adjust_checkout_fee_bps(300, actor: admin,
                                      expected_version: overview.version)
# a CAS write returns the NEW token — chain it into the next write:
Dials.clear_checkout_fee_bps(actor: admin, expected_version: token)
```

The token is opaque: obtain it from `overview` or a CAS write's return
value and echo it back — never construct or parse one. Any successful write
(CAS or not) moves the version. `expected_version` is a reserved dimension
name, like `actor`. Passing nothing keeps today's unconditional
last-write-wins, and unconditional writes keep their usual return values
(the value for set, the boolean for clear). The staleness check runs even
when a clear would be a no-op — a page showing an override that no longer
exists is stale.

On `StaleWrite`, re-render from a fresh `Dials.overview` and let the
operator decide again; retrying automatically would defeat the mechanism
(the stores deliberately never auto-retry it).

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
  config.default_actor = nil           # fallback attribution; see below
end
```

### `config.default_actor`

Fallback attribution for writes that pass no `actor:` — for apps without
user identity (no User model, single-operator tools, scripts). A
string/object, or a callable evaluated per write:

```ruby
config.default_actor = "anonymous"                        # log, anonymously
config.default_actor = -> { ENV.fetch("USER", "console") } # log the OS user
```

`nil` (the default) keeps `actor:` required on every write. An explicit
`actor:` always wins over the default. This is a declared app-level
fallback, not discovery — the gem still never guesses (no `Current.user`
magic).

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
| `InvalidValue` | wrong type, schema violation, or nil on write/pin |
| `InvalidScope` | wrong/missing/unknown dimensions or values |
| `MissingActor` | write without `actor:` and no `config.default_actor` declared |
| `StaleWrite` | `expected_version:` no longer matches the store — unapplied, unlogged |

# API Reference

## Declaration

### `Dials.define(&block)`

Runs the block against the registry. Blocks accumulate; a duplicate key
raises `Dials::DuplicateDial` at boot.

### `dial(key, default:, type:, label: nil, unit: nil, description: nil, dimensions: nil, validate: nil, **constraints)`

Declares one dial (inside a `define` block). Raises
`Dials::InvalidDefinition` at boot when the declaration is malformed, a
constraint keyword doesn't apply to the type, the default fails its own
schema, or a generated method name is already taken.

Each declaration generates the dial's three methods on its namespace
(`Dials` itself, for the default one): the bare `<key>` reader,
`adjust_<key>`, and `clear_<key>` (see below). They are defined at
declaration time — real methods, not `method_missing`. Because the reader is
the bare name, a dial cannot share a name with an existing method on that
namespace (`:store`, `:cache`, `:changes`, ...) — that raises at boot.

| Argument | Type | Required | Notes |
|---|---|---|---|
| `key` | Symbol/String | yes | unique inside its namespace; the only positional argument |
| `default:` | value | yes | the code default; validated like any stored value |
| `type:` | Symbol | yes | `:boolean` `:integer` `:float` `:string` `:json` |
| `label:` | String | no | defaults to the humanized key |
| `unit:` | String | no | display metadata (`"bps"`, `"cents"`, `"hours"`) |
| `description:` | String | no | shown on admin surfaces; write one |
| `dimensions:` | Hash or Array | no | dimensions; see below |
| `validate:` | callable | no | escape hatch for rules a schema cannot express; returns truthy for storable. Not serializable — prefer the schema keywords |
| *constraints* | keywords | no | value constraints in JSON Schema's vocabulary; see below |

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

`dimensions:` shapes, all equivalent where applicable:

```ruby
dimensions: { market: { enum: %w[KE NG BD] } }      # canonical
dimensions: { market: %w[KE NG BD] }                # shorthand: enum array
dimensions: { market: -> { Market.pluck(:code) } }  # callable, resolved lazily
dimensions: { locale: {} }                          # open: any non-empty string
dimensions: [:market, :platform]                    # names only, all open
```

`actor` is a reserved dimension name — on the generated `adjust_`/`clear_`
methods it always means attribution, never scope.

## Reading

### `Dials.<key>(**scope) → value`

The generated reader:

```ruby
Dials.signups_enabled                  # global-only dial
Dials.checkout_fee_bps(market: "KE")   # varied dial
```

Resolves scoped override → global override → code default. Scope must name every
declared dimension exactly (values compared as strings). Raises
`Dials::InvalidScope`. Returned `:json` values are deep-frozen; hash keys
are strings.

### `Dials.get(key, **scope) → value`

The key-taking primitive under the bare `<key>` reader, for code that
receives the key at runtime (an admin surface, a console). Same semantics;
also raises `Dials::UnknownDial` for an undeclared key.

### `Dials.global(key) → value`

A dial's **Global layer**: the stored global override when present, else the
code default — the tail every un-overridden scope falls through to.

```ruby
Dials.global(:checkout_fee_bps)   # never sees per-market overrides
```

This is the front door for the caller that has *no scope to give* — resolving
a value for a subject whose dimension is unknowable (say, a recipient with no
resolvable market). It is explicitly **not** a way around exact-scope reads:
a caller that knows its scope must still pass it to `get`, which raises
`Dials::InvalidScope` precisely so a lazy read cannot skip a scoped override.
For a dial with no dimensions it is equivalent to `get`. Raises
`Dials::UnknownDial`; honors `Dials::Testing.with_overrides` pins.

### `Dials.scoped_overrides(key) → { scope => value }`

One dial's stored scoped overrides, keyed by **parsed** scope hashes (never
canonical scope strings) — "which markets have an override for this dial":

```ruby
Dials.scoped_overrides(:checkout_fee_bps)   # => { { market: "BD" } => 120,
                                      #      { market: "NG" } => 180 }
```

`{}` when nothing scoped is stored (or the dial declares no dimensions); raises
`Dials::UnknownDial` for undeclared keys. Reads through the same snapshot
path as every other read (in-transaction rule included); the result is
deep-frozen.

### `Dials.overview → Overview`

Every registered dial's full state — the `Definition` (with `json_schema`),
whether a global override exists and its value, and its scoped overrides — read
from ONE snapshot in one call, so an admin page renders a coherent picture
stamped with a single version:

```ruby
overview = Dials.overview
overview.version                    # store write-clock token (informational)
overview.dials.each do |state|
  state.key                         # :checkout_fee_bps
  state.definition                  # the Definition
  state.json_schema                 # JSON Schema fragment for this dial
  state.global_override?            # explicitly present-or-absent...
  state.global_value                # ...because false ≠ "no override"
  state.global_version              # the global's stale-write token
                                    # (Dials::ABSENT_VERSION when not stored)
  state.scoped_overrides                  # { parsed scope => value }
  state.scoped_override_versions          # { parsed scope => stale-write token }
end
```

All returned structures are frozen.

### `Dials.changes(key: nil, limit: 50) → [ChangeRecord]`

Newest-first history. `ChangeRecord` is a Data class:
`key, scope, action ("set"/"clear"), old_value, new_value, actor_type,
actor_id, actor_label, created_at`, plus `#global?`.

### `Dials.registry`

Enumerable of `Dials::Definition`. Useful members for building UIs:

```ruby
Dials.registry.keys                 # [:checkout_fee_bps, ...]
Dials.registry.fetch(:key)          # Definition (raises UnknownDial)
Dials.registry.defined?(:key)       # true/false
definition.key .default .type .label .unit .description
definition.dimensions?              # any dimensions?
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
Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")  # scoped
```

Stores an override — global with no scope keywords, scoped with them.
Validates type, schema, and scope; requires `actor:` (which is why `actor`
is a reserved dimension name). Appends to the change log and busts the local
cache. Raises `Dials::InvalidValue`, `Dials::InvalidScope`,
`Dials::MissingActor`.

### `expected_version:` — stale-write protection

Every write path (generated and primitive) accepts `expected_version:`,
which makes the write **compare-and-swap against the override it targets**
(the global when there are no scope keywords, the named scoped override
otherwise): pass that override's token from `Dials.overview` — or
`Dials::ABSENT_VERSION` when the page showed no override stored — and the
write is refused with `Dials::StaleWrite`, unapplied and with nothing
appended to the change log, if the override has changed since. The
comparison is atomic with the write via the database's own row primitives
(guarded `UPDATE`/`DELETE`, the unique index for inserts): of two concurrent
writes carrying the same token, exactly one commits, and an unconditional
write interleaving has the same effect — nothing needs to opt in for the
guarantee to hold. Writes to *other* overrides never conflict.

```ruby
state = Dials.overview.dials.find { |s| s.key == :checkout_fee_bps }
# ... operator looks at the page, decides ...
token = Dials.adjust_checkout_fee_bps(300, actor: admin,
                                      expected_version: state.global_version)
# a CAS write returns the override's NEW token — chain the next write:
Dials.clear_checkout_fee_bps(actor: admin, expected_version: token)
# a CAS clear returns Dials::ABSENT_VERSION: the override is gone
```

Tokens are opaque: obtain them from `overview` or a CAS write's return value
and echo them back — never construct or parse one (`Dials::ABSENT_VERSION`
is the one well-known constant, and it strictly means "never written":
cleared overrides keep a tombstone token, so an old "absent" assertion goes
stale the moment any set/clear touches the stream — no ABA). A CAS clear
returns the tombstone's token, which chains into a later set. A token minted
inside a database transaction that rolls back is void — it describes a write
that never happened. `expected_version` is a reserved dimension name, like
`actor`. Passing nothing keeps unconditional last-write-wins, and
unconditional writes keep their usual return values (the value for set, the
boolean for clear). The staleness check runs even when a clear would be a
no-op — a page showing an override that no longer exists is stale.

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

## Configuration

```ruby
Dials.configure do |config|
  config.store = :active_record        # or :memory, or any store instance
  config.cache_ttl = 5.0               # seconds; 0 = probe every read; nil = never
  config.actor_label = ->(actor) { }   # change-log label builder
  config.default_actor = nil           # fallback attribution; see below
  config.table_name_prefix = nil       # "ops_" names the root's table ops_dials; see below
end
```

### `config.table_name_prefix`

Prefix for the **default** namespace's table, when `dials` collides with an
existing table. Used verbatim — include the trailing underscore, as with Rails'
`table_name_prefix`:

```ruby
config.table_name_prefix = "ops_"   # the table is ops_dials
```

The migration must create the matching table; pass the same prefix to the
install generator so both stay in step:

```bash
bin/rails generate dials:install --table-name-prefix=ops_
```

`nil` (the default) keeps `dials`. Every other namespace names its table
with `config.table_name` instead — setting `table_name_prefix` on one
raises `Dials::Error`.

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

## Namespaces

A namespace is a dials instance of its own: its own registry, config, store,
table, cache and change log. `Dials` is the default one (name `:default`),
and every method on the module reads and writes through it. See
[Namespaces](/guides/namespaces) for what a namespace owns, what it inherits,
and when to declare one.

### `Dials.namespace(name, label: nil, &block) → Namespace`

Declares a namespace when you pass a block or a `label:`. Fetches the one
already declared under that name when you pass neither.

```ruby
Shipping = Dials.namespace(:shipping, label: "Shipping") do |config|
  config.store = :active_record      # table: "shipping_dials"
  config.table_name = "other_name"   # optional; renames the table
  config.label = "Shipping"          # same as the label: argument
end

Dials.namespace(:shipping)           # the same object, later
```

Options the block leaves alone (`cache_ttl`, `actor_label`, `default_actor`)
read through to the root's config. `store` inherits by *kind*, so an
inheriting namespace still owns its own table; a store *object* is never
inherited, and a namespace under one must name its own store or reading a
dial raises `Dials::Error`.

Raises `Dials::DuplicateNamespace` for a name declared twice,
`Dials::UnknownNamespace` for a fetch of one never declared, and
`Dials::InvalidNamespace` for a name whose segments are not lowercase
letters and digits, each starting with a letter, joined by single
underscores — the name becomes a table name and a model class name, and
that rule is what keeps both one-to-one with the namespace.

### `config.table_name`

The table a namespace owns. Defaults to `<name>_dials`; the root's is
`dials` (see `config.table_name_prefix`).

A table name is lowercase letters, digits and underscores, at most 63
characters — it reaches raw SQL unquoted, and PostgreSQL truncates
identifiers past 63 bytes. Two namespaces may never resolve to one table:
sharing one would interleave their keys, history and stale-write sequences
with nothing to tell them apart. Either raises `Dials::InvalidTableName` at
boot.

### `Dials.namespaces → [Namespace]`

Every namespace, root first, then declaration order. An admin page walks it
to group dials by subsystem:

```ruby
Dials.namespaces.map { |ns| [ns.name, ns.label, ns.overview.dials] }
```

### `Dials.default → Namespace`

The root namespace, named explicitly.

### The namespace API

Everything documented above, on the namespace object:

```ruby
ns.name                 # :shipping
ns.label                # "Shipping" (config.label; the root's is "Dials")
ns.define { dial ... }
ns.configure { |config| ... }
ns.registry / ns.config / ns.store / ns.cache
ns.max_parcel_kg                                       # generated reader
ns.adjust_max_parcel_kg(30, actor:, expected_version:) # generated writer
ns.clear_max_parcel_kg(actor:, expected_version:)      # generated clear
ns.get / ns.set / ns.clear / ns.scoped_overrides
ns.overview             # one snapshot of this namespace's dials
ns.changes(key: nil, limit: 50)                        # its own log only
ns.with_overrides(max_parcel_kg: 5) { ... }            # thread-local pin
ns.reload! / ns.reset_cache!
```

A dial resolves inside its namespace: there is no cross-namespace fallback,
and two namespaces may declare the same key.

## Testing

### `Dials::Testing.with_overrides(hash, &block)`

Thread-local, validated, nestable value pinning for the block's duration.
Applies to every scope of each pinned dial; never touches store, cache, or
log. It pins the default namespace. Another namespace pins its own dials
through itself (`Shipping.with_overrides(...)`), and a pin on one namespace
does not change what another returns.

### `Dials.reload_all!`

`reload!` for every namespace: one call for a suite that wraps examples in
transactions.

### `Dials.reset_namespaces!`

Test hook: discards every namespace but the root, and with them their
registries and generated methods. Use it in a suite that declares namespaces
and wants a blank slate per example.

## Stores

A store is any object implementing the interface documented in
[`Dials::Stores::Memory`](https://github.com/zarpay/dials/blob/main/gem/lib/dials/stores/memory.rb)
(`state`, `version`, `override_version`, `set_override`, `clear_override`,
`changes` — the global override is the one at `Scope::GLOBAL`, the canonical
empty scope; the write methods return `[result, stamp]` so tokens come from
the write itself, never a second read). Shipped: `Stores::Memory` (default) and
`Stores::ActiveRecordStore` (via `require "dials/active_record"`).

## Generator

```bash
bin/rails generate dials:install
bin/rails generate dials:install --table-name-prefix=ops_   # table: ops_dials
```

Creates the migration for the gem-owned table and
`config/initializers/dials.rb`. A [namespace](/guides/namespaces) is not
generated — it needs one table like this one and a few lines in an
initializer.

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
| `StaleWrite` | `expected_version:` no longer matches the targeted override — unapplied, unlogged |
| `WriteConflict` | concurrent unconditional writes to one override outran the store's retries (effectively never) |
| `DuplicateNamespace` | a namespace declared twice |
| `UnknownNamespace` | a namespace fetched that was never declared |
| `InvalidNamespace` | a namespace name that is not a lowercase, underscore-separated identifier |
| `InvalidTableName` | a table name that is not a plain identifier, is over 63 characters, or is already another namespace's |

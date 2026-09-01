# Variants and Scopes

## Dimensions belong to the dial

Different dials vary along different axes. Bazario's fee varies by market;
its delivery threshold varies by market **and** platform; its banner copy
varies by locale; its kill switch must never vary at all. So variant
dimensions are declared per dial:

```ruby
dial :checkout_fee_bps, default: 250, type: :integer,
     variants: { market: { options: %w[KE NG BD] } }

dial :free_delivery_threshold, default: 5_000, type: :integer,
     variants: { market: { options: %w[KE NG BD] },
                 platform: { options: %w[ios android web] } }

dial :welcome_banner, default: { "headline" => "Welcome" }, type: :json,
     variants: { locale: {} }        # open dimension: any non-empty string

dial :signups_enabled, default: true, type: :boolean   # no variants: global-only
```

A dimension with `options:` validates every scope value against the list
(an `Array` or a callable resolved on first use — e.g.
`-> { ISO3166::Country.codes }`). An open dimension accepts any non-empty
string. Dimension values are compared as strings: `market: :KE` and
`market: "KE"` are the same scope.

One name is reserved: a dimension cannot be called `actor`. On the generated
`adjust_`/`clear_` methods scope travels as bare keywords next to `actor:`,
which must always mean attribution.

## Declaring variants IS the arming gate

A dial with no `variants:` cannot hold a variation — the write is rejected,
not ignored. This is a process invariant disguised as an API:

> Add the `variants:` declaration in the same PR as the code that reads the
> varied value.

Without the gate, an operator can create a "BD = 24" row that nothing
consumes. It silently does nothing today — and months later, when a reader
ships, the stale forgotten row suddenly takes effect in production. With the
gate, a scope cannot be configured before something consumes it, and the
diff that arms a dial is visible in review. The demo app pins its armed
dials in a registry-integrity spec
([`spec/dials/registry_spec.rb`](https://github.com/zarpay/dials/blob/main/demo/spec/dials/registry_spec.rb))
so arming one more dial fails a test until the pin is deliberately updated.

The same logic gives you global-only dials for free: a kill switch declared
without `variants:` *cannot* be half-off in one market, even by a determined
operator with production console access to the API.

## The exact-scope rule (v1)

Both reads and writes must name **every** declared dimension:

```ruby
Dials.use_free_delivery_threshold(market: "KE", platform: "ios")   # ✓
Dials.use_free_delivery_threshold(market: "KE")                    # InvalidScope
Dials.use_free_delivery_threshold                                  # InvalidScope
Dials.use_signups_enabled(market: "KE")                            # InvalidScope
```

One sentence to remember: **a variation matches exactly, or you get the
global.** No precedence table, no "which partial wins" question, nothing to
misremember at 2am.

## Canonical scopes

Stored scopes are canonicalized — keys sorted, values stringified — so
`{ platform: :ios, "market" => "KE" }` and `{ market: "KE", platform: "ios" }`
are one scope, enforced by a unique index on `(dial_id, scope)`. A scope
written once can never be re-stored under a cosmetically different spelling.

## The path to partial scopes (if ever needed)

Sometimes you will want `{ market: "KE" }` to cover every platform without
writing three rows. That is a **partial scope**, and the gem is built so
adding it later is a write-side relaxation, not a redesign:

- The resolver already implements the general rule: a stored scope matches a
  request when every pair it names appears in the request; the **most
  specific** match (most dimensions named) wins; ties break by the dial's
  declared dimension order (declare `market` before `platform` and the
  market partial outranks the platform partial).
- The storage model (canonical scope strings) represents partial scopes
  today.
- Only `Scope.validate!(..., exact: true)` on the write path stands between
  v1 and partials — and the resolver's partial-scope behavior is already
  pinned by the gem's tests.

v1 ships exact-only because partial precedence is a concept operators must
hold in their heads, and the right time to charge that cost is when a real
need arrives — not before. Whether it ever ships is tracked in
[Possible Enhancements](/design/possible-enhancements).

# Testing with Dials

Two audiences: testing code that *consumes* dials, and keeping the suite
honest about the dial layer itself.

## Pin values with `with_overrides`

```ruby
it "charges the configured fee" do
  Dials::Testing.with_overrides(checkout_fee_bps: 1_000) do
    expect(quote.fee_cents).to eq(1_000)
  end
end
```

Properties worth knowing:

- Applies **for every scope** of the dial, on the current thread, for the
  block's duration. It never touches the store, the cache, or the change log.
- **Validated**: pinning `checkout_fee_bps: "cheap"` raises
  `Dials::InvalidValue` — a test cannot hold a value production could never
  hold. (Compare `stub_const`, which happily stubs nonsense.)
- **Nests**: inner blocks win, and everything restores on exit.
- **Doesn't relax reads**: an invalid scope still raises inside the block. A
  test override can't mask a call-site bug.
- `false` pins fine — kill-switch specs work.

Prefer `with_overrides` for consumer specs. Reach for real `Dials.set` writes
only when the *dial layer itself* is what you're testing (resolution,
history, the write surface).

## The one line of hygiene

With transactional specs, an example's `Dials.set` rolls back with the
transaction — but the per-process **cache** would keep serving the value into
later examples. Reset it:

```ruby
# spec/support/dials.rb
RSpec.configure do |config|
  config.before { Dials.reload! }
end
```

(Minitest: `Dials.reload!` in your base-class `setup`.)

## The registry-integrity spec

Pin what your app declares, so changes to operator capabilities are visible,
deliberate diffs:

```ruby
RSpec.describe "Dial registry" do
  it "declares exactly the expected dials" do
    expect(Dials.registry.keys).to contain_exactly(
      :checkout_fee_bps, :signups_enabled
    )
  end

  it "pins which dials are armed for variation" do
    armed = Dials.registry.select(&:variants?).to_h { |d| [d.key, d.dimension_names] }
    expect(armed).to eq(checkout_fee_bps: [:market])
  end
end
```

Arming a dial (adding `variants:`) now fails a test until the pin is updated
in the same PR — which forces the [arming-gate
discipline](/concepts/variants-and-scopes) through review.

## Testing the gem's own behavior in your app

You mostly shouldn't — the gem's suite and the
[demo app's suite](https://github.com/zarpay/dials/tree/main/demo/spec) cover
resolution, caching, and the change log. The exceptions worth writing in
your app: your write surface (auth, error mapping, `false` over the wire)
and your registry pins.

## Store choice in tests

The demo runs `:active_record` in test so its suite proves persistence. Apps
that only *consume* dials can set `config.store = :memory` in the test
environment for a suite that never touches the dial tables — every
`Dials.set` still validates and logs identically against the in-memory store.

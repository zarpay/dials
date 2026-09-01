# Caching

Dials are read in hot paths — pricing every checkout, gating every signup —
so reads cannot cost a query. The cache design has three properties, in
priority order: reads are memory-only, a process always sees its own writes
immediately, and all processes converge within a bounded interval.

## The snapshot

Each process holds one immutable **Snapshot**: every stored global override
and every scoped override — each stream's newest row — loaded in one query
(plus one for the version),
deep-frozen. A read
(`Dials.checkout_fee_bps(market: "KE")`) is a registry lookup plus a
hash lookup into the snapshot. The demo app pins this
with a spec that runs 100 reads under a SQL subscriber and asserts **zero
queries**.

Values are deep-frozen because reads hand out references into the shared
snapshot — a caller mutating a returned `:json` hash would otherwise corrupt
what every other thread reads.

## Freshness: two mechanisms

**1. Local writes bust immediately.** Every write (`adjust_*`, `clear_*`, or
the `set`/`clear` primitives) discards the process's snapshot on the way
out. The admin who changed a value sees the change on the very next read, no
matter what the probe interval is.

**2. Other processes converge via the staleness probe.** A cache busted in
one Puma worker says nothing to the other 30 workers on 4 machines. Instead
of pub/sub infrastructure, each process asks the store for its **version** at
most once per `cache_ttl` seconds during reads, and rebuilds only when the
version moved:

```ruby
Dials.configure do |config|
  config.cache_ttl = 5.0   # default; 0 = probe every read; nil = never probe
end
```

The version is the table's **row count plus max id**. The table is
append-only — every write, set or clear, INSERTs exactly one row — so the
version moves on every write by construction (there are no deletions for a
heartbeat to miss). The count matters:
max id alone has a gap-commit hole — transaction A claims id 10, B claims
and commits id 11, then A commits; a process that already probed 11 would
never see A's write. The table is append-only, so the count is
commit-monotonic and closes the gap.

The worst case after a write: every other process serves the old value for at
most `cache_ttl` seconds, then converges. The cost of the mechanism: one
trivial query per process per interval. There is no cross-process immediate
consistency setting, because no polling design can provide one — if you
believe you need it, what you actually need is to pass the value explicitly.

## Failure behavior

Once a process holds a snapshot, a probe or rebuild failure serves
**last-known-good** with a warning — a database blip must not take down
every dial read (the values it's serving were true moments ago, and the
next healthy probe converges). Only a cold start with no snapshot at all
raises: there, nothing honest exists to serve.

Two other concurrency properties the cache guarantees: the store is never
queried while a lock is held (a mutex held across a connection checkout can
deadlock a multi-threaded server's pool), and a stale refresh is
single-flight — threads that lose the rebuild race serve the current
snapshot instead of stampeding the database.

## Writes inside application transactions

If a dial write runs inside one of your own database transactions, the
uncommitted value must not leak into the shared cache (other threads would
read it; a rollback would leave it behind). The gem handles this: the
writing thread reads its own uncommitted state through fresh, unpublished
snapshots until the transaction closes, and then rejoins the shared cache —
which never held the uncommitted value at any point. Other threads see the
write only after commit, via the normal probe.

## The escape hatches

- `Dials.reload!` — force this process to rebuild on the next read. Needed
  after writes that bypass the gem (a direct SQL edit, a row created in a
  console through the models): those skip the change log, so the version
  counter cannot see them. This is one of several reasons direct writes are
  discouraged.
- `cache_ttl = 0` — probe on every read. One extra `MAX(id)` query per read;
  useful in low-traffic admin processes that must never be stale.
- `cache_ttl = nil` — never probe. For single-process scripts and consoles
  that prefer explicit `Dials.reload!`.

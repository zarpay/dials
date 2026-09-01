# Compared to Alternatives

Dials occupies a specific spot: **operator-owned runtime values with variant
dimensions**. Each neighbor below is excellent at its own spot, and the
right answer is often "both, for different values".

## ultra_settings

[ultra_settings](https://github.com/bdurand/ultra_settings) resolves
configuration through layers — environment variables → runtime settings →
YAML — with typed fields declared in code and a read-only web UI.

- **Its problem**: *deploy/environment configuration* — values that differ by
  environment and change with deploys, unified behind one API.
- **What it lacks for the dials problem**: variant dimensions (its only axis
  is the Rails environment), write attribution, validation with teeth, and a
  first-class override/clear model.
- **What dials lacks for its problem**: ENV and YAML layers, deliberately —
  a dial changing per-environment via ENV would undermine "the change log is
  the history".

Use ultra_settings for `DATABASE_POOL_SIZE`; use dials for
`checkout_fee_bps`.

## super_settings

[super_settings](https://github.com/bdurand/super_settings) is the closest
relative: database-backed runtime settings, editable UI, change history,
and a polling cache (its design validated ours). Differences that matter:

- **Registry**: super_settings' settings are *created at runtime* in the UI;
  dials must be *declared in code* — key, type, constraints, dimensions — so
  review owns the shape and the value can't outlive its reader.
- **Variants**: super_settings has one value per key; per-market values
  land you back in key-naming conventions (`fee_bps_ke`, `fee_bps_ng`) with
  no fallback semantics. Variants are dials' reason to exist.
- **Defaults**: super_settings defaults live at the call site
  (`Setting.fetch(key, default)`), dials' at the declaration — one place,
  reviewed, validated at boot.

## Flipper (feature flags)

[Flipper](https://github.com/flippercloud/flipper) answers "**who** gets
this behavior?" — booleans with actors, groups, and percentage rollouts,
built for gradual release and experimentation. Dials answers "**what is the
value** here?" — typed quantities with variant fallback. The overlap is the
plain boolean kill switch, which either tool handles; if you're already
running Flipper, keep your flags there and bring dials in when the values
stop being booleans. Percentage-of-actors on a dial is a non-goal.

## ENV vars / Rails credentials

Deploy-shaped and secret-shaped configuration respectively. Neither is
operator-adjustable at runtime, neither has attribution or history, and
that's correct for what they hold. The
[pattern boundary](/concepts/pattern-boundary) page draws this line in
detail.

## A hand-rolled settings table

The default alternative, because it's an afternoon's work. The afternoon
buys the middle of the arc; the years buy the rest piecemeal and under
incident pressure: type casting, value constraints, `false` vs `NULL`, per-market rows
and their sentinel, fallback reads, cache invalidation across processes,
attribution, and "who changed this at 3am". Dials is that list, done once,
with the sharp edges named and tested.

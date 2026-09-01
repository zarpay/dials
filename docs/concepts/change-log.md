# The Change Log

Operators changing production values is the entire point of this gem — which
makes "who changed what, when, from what, to what" a core feature, not an
audit afterthought.

## Every write is attributed

Every write path — the generated `adjust_`/`clear_` methods and the `set`/
`clear` primitives beneath them — requires `actor:`. Passing `nil` raises
`Dials::MissingActor`. There is no anonymous mutation path through the
public API:

```ruby
Dials.adjust_checkout_fee_bps(120, actor: current_admin, market: "BD")
```

The actor can be any object. An ActiveRecord-ish object contributes its class
name and id; the label defaults to `email`, then `name`, then
`"ClassName#id"`, and is configurable app-wide:

```ruby
Dials.configure do |config|
  config.actor_label = ->(actor) { actor.email }
end
```

The gem deliberately does **not** discover the actor itself (no
`Current.user` magic): the write surface you build is where authentication
lives, so the actor is explicit at the call site. See
[Build a Write Surface](/guides/build-a-write-surface).

## Apps without user identity

Attribution never required a User model: `actor:` takes any object, and
strings are first-class — `actor: "keith — BD launch"` from a console is a
fully attributed write. For apps with no identity to pass at all
(single-operator tools, scripts), declare a fallback once and `actor:`
becomes optional:

```ruby
Dials.configure do |config|
  config.default_actor = "anonymous"                         # log, anonymously
  # config.default_actor = -> { ENV.fetch("USER", "console") } # or per write
end
```

The log keeps everything else (what changed, when, old → new); only the
"who" degrades to the declared fallback. An explicit `actor:` always wins,
and with no `default_actor` configured, writes without `actor:` raise
`MissingActor` exactly as before — the fallback is something an app
declares in a reviewed initializer, never something the gem assumes.

## The log is append-only

Every write lands one row in `dial_changes`:

| Column | Contents |
|---|---|
| `key` | which dial |
| `scope` | canonical scope string, `NULL` for global changes |
| `action` | `set` or `clear` |
| `old_value` / `new_value` | JSON; `old_value NULL` when no override existed, `new_value NULL` on clear |
| `actor_type` / `actor_id` / `actor_label` | attribution |
| `created_at` | when |

There is no `updated_at` — rows are facts, never edited. No-op clears
(clearing an override that does not exist) log nothing.

Read it back in store-independent form:

```ruby
Dials.changes(limit: 100)                  # everything, newest first
Dials.changes(key: :checkout_fee_bps)      # one dial's history
# => [ChangeRecord(key:, scope:, action:, old_value:, new_value:,
#                  actor_type:, actor_id:, actor_label:, created_at:), ...]
```

This is the data for the history views and chart annotations your admin
surface renders ("fee changed here" markers on a conversion graph).

## The log is also the clock

The change log's max id is the store's version counter — the thing the
[cache staleness probe](/concepts/caching) watches. That is a deliberate
two-birds design: because every legitimate write appends here, "has anything
changed?" is one indexed query, and writes that *bypass* the gem are exactly
the writes the probe cannot see. Retention pruning of `dial_changes` would
break both history and (if it removed the max row) the clock; don't prune it.
At operator scale — humans turning knobs — it grows slowly forever, and
that's fine.

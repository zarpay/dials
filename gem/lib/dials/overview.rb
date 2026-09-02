# frozen_string_literal: true

module Dials
  # The complete stored state of every registered dial, read from ONE
  # snapshot in one call — so an admin page renders a coherent picture.
  #
  #   overview.version         # the store's write-clock token (informational:
  #                            # "rendered as of"; freshness displays, cheap
  #                            # did-anything-change checks)
  #   overview.dials           # [DialState, ...] in registry order
  #
  # Stale-write tokens are PER OVERRIDE — see DialState#global_version and
  # #scoped_override_versions; feed those back as `expected_version:` on writes.
  Overview = Data.define(:version, :dials)

  # One dial's declaration plus its stored overrides at the snapshot moment.
  #
  # `global_override?` is explicit — a boolean dial overridden to `false`
  # must never be confusable with "no override" (`global_value` alone could
  # not distinguish them; it is nil when no global override exists).
  #
  # `global_version` and `scoped_override_versions` are the per-override
  # stale-write tokens: echo the one for the override you are writing as
  # `expected_version:`. Cleared overrides keep a TOMBSTONE token (the
  # stream's clear stamp) — so `scoped_override_versions` can carry entries
  # for scopes with no value in `scoped_overrides`, and `global_version` is
  # Dials::ABSENT_VERSION only when the global was never written at all.
  # For an override with no token listed anywhere, pass
  # Dials::ABSENT_VERSION to assert it has never been written.
  DialState = Data.define(:definition, :global_override, :global_value, :global_version,
                          :scoped_overrides, :scoped_override_versions) do
    def key
      definition.key
    end

    def global_override?
      global_override
    end

    # The declaration as a JSON Schema fragment (see Definition#to_json_schema).
    def json_schema
      definition.to_json_schema
    end
  end
end

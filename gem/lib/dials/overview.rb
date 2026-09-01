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
  # `expected_version:`. A missing entry (or a global_version of
  # Dials::ABSENT_VERSION) means "no override stored" — pass
  # Dials::ABSENT_VERSION to assert it is still absent when you write.
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

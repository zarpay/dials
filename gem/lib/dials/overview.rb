# frozen_string_literal: true

module Dials
  # The complete stored state of every registered dial, read from ONE
  # snapshot in one call — so an admin page renders a coherent picture
  # stamped with a single `version` token (feed it back as
  # `expected_version:` on writes for stale-write protection).
  #
  #   overview.version         # opaque store-version token (String)
  #   overview.dials           # [DialState, ...] in registry order
  Overview = Data.define(:version, :dials)

  # One dial's declaration plus its stored overrides at the snapshot moment.
  #
  # `global_override?` is explicit — a boolean dial overridden to `false`
  # must never be confusable with "no override" (`global_value` alone could
  # not distinguish them; it is nil when no global override exists).
  DialState = Data.define(:definition, :global_override, :global_value, :variations) do
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

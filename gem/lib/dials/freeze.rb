# frozen_string_literal: true

module Dials
  # Recursive freeze for JSON-shaped values (hashes, arrays, scalars). Used on
  # snapshot contents and on declaration defaults, so no code path can hand a
  # caller a mutable reference into shared dial state.
  module Freeze
    module_function

    def deep(object)
      case object
      when Hash
        object.each { |k, v| deep(k) && deep(v) }
      when Array
        object.each { |v| deep(v) }
      end
      object.freeze
    end
  end
end

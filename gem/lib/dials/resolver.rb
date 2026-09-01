# frozen_string_literal: true

module Dials
  # Resolution: scoped override → global override → code default.
  #
  # The matcher is deliberately more general than v1 needs. A stored scope
  # matches a request when every pair it names is present in the request
  # (subset match), and the most specific match — the one naming the most
  # dimensions — wins, with ties broken by the dial's declared dimension
  # order. Under the v1 write rule (stored scopes always name every declared
  # dimension) this degenerates to exact-match-or-global, but relaxing the
  # write rule later enables partial scopes ({market: "KE"} covering every
  # platform) with no change here.
  module Resolver
    module_function

    # `scope` is already normalized and validated. Returns the resolved value.
    def resolve(definition, scope, snapshot)
      stored = snapshot.scoped_overrides[definition.key]
      if stored && !stored.empty? && !scope.empty?
        match = best_match(definition, scope, stored)
        return match[1] if match
      end

      snapshot.globals.fetch(definition.key) { definition.default }
    end

    def best_match(definition, scope, stored)
      candidates = stored.filter_map do |canonical, value|
        stored_scope = Scope.parse(canonical)
        next unless stored_scope.all? { |name, v| scope[name] == v }

        [stored_scope, value]
      end
      return nil if candidates.empty?

      priority = definition.dimension_names.each_with_index.to_h
      candidates.max_by do |stored_scope, _value|
        # More named dimensions wins; among equals, earlier-declared
        # dimensions outrank later ones (compared most-significant first).
        [stored_scope.size, definition.dimension_names.map { |n| stored_scope.key?(n) ? priority.size - priority[n] : 0 }]
      end
    end
  end
end

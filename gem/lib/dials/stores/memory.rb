# frozen_string_literal: true

module Dials
  module Stores
    # The reference store: plain hashes behind a mutex. It is the default
    # store so the gem works out of the box (and in client test suites)
    # without a database, and it doubles as the executable specification of
    # the store interface:
    #
    #   state                                  → { globals:, variations:, version: }
    #   version                                → monotonic value, moves on every write
    #   set_global(key, value, actor)          → previous value or nil
    #   clear_global(key, actor)               → true if an override existed
    #   set_variation(key, canonical, value, actor) → previous value or nil
    #   clear_variation(key, canonical, actor) → true if a variation existed
    #   changes(key: nil, limit: 50)           → newest-first [ChangeRecord]
    #
    # `actor` is the normalized hash from Dials::Actor. Value validation and
    # scope validation happen above the store; a store only persists.
    #
    # Values are round-tripped through JSON on write, exactly like the
    # ActiveRecord store. That buys two guarantees at once: the store never
    # retains a reference to a caller-owned mutable object (mutating a hash
    # after Dials.set cannot silently change the stored override or rewrite
    # change-log history), and both stores return byte-identical shapes
    # (symbol keys become strings here too, so a test suite on the memory
    # store proves what production on ActiveRecord will do).
    class Memory
      def initialize
        @globals = {}
        @variations = Hash.new { |h, k| h[k] = {} }
        @changes = []
        @version = 0
        @mutex = Mutex.new
      end

      def state
        @mutex.synchronize do
          {
            globals: @globals.transform_values { |v| dup_value(v) },
            variations: @variations.to_h { |k, scopes| [k, scopes.transform_values { |v| dup_value(v) }] },
            version: @version
          }
        end
      end

      def version
        @mutex.synchronize { @version }
      end

      def set_global(key, value, actor)
        @mutex.synchronize do
          stored = roundtrip(value)
          old = @globals[key]
          @globals[key] = stored
          record(key, nil, "set", old, stored, actor)
          old
        end
      end

      def clear_global(key, actor)
        @mutex.synchronize do
          next false unless @globals.key?(key)

          old = @globals.delete(key)
          record(key, nil, "clear", old, nil, actor)
          true
        end
      end

      def set_variation(key, canonical_scope, value, actor)
        @mutex.synchronize do
          stored = roundtrip(value)
          old = @variations[key][canonical_scope]
          @variations[key][canonical_scope] = stored
          record(key, canonical_scope, "set", old, stored, actor)
          old
        end
      end

      def clear_variation(key, canonical_scope, actor)
        @mutex.synchronize do
          next false unless @variations.key?(key) && @variations[key].key?(canonical_scope)

          old = @variations[key].delete(canonical_scope)
          @variations.delete(key) if @variations[key].empty?
          record(key, canonical_scope, "clear", old, nil, actor)
          true
        end
      end

      def changes(key: nil, limit: 50)
        @mutex.synchronize do
          selected = key ? @changes.select { |c| c.key == key.to_sym } : @changes
          selected.last(limit).reverse
        end
      end

      private

      # Callers hold the mutex. Old/new values are duplicated (so a change
      # record never shares structure with the live store state) and frozen
      # (so a caller mutating what Dials.changes returned cannot rewrite the
      # retained history — the ActiveRecord store decodes fresh per call and
      # has no equivalent hazard).
      def record(key, canonical_scope, action, old_value, new_value, actor)
        @version += 1
        @changes << ChangeRecord.new(
          key: key,
          scope: canonical_scope && Freeze.deep(Scope.parse(canonical_scope)),
          action: action,
          old_value: Freeze.deep(dup_value(old_value)),
          new_value: Freeze.deep(dup_value(new_value)),
          actor_type: actor[:actor_type],
          actor_id: actor[:actor_id],
          actor_label: actor[:actor_label],
          created_at: Time.now.utc
        )
      end

      def roundtrip(value)
        JSON.parse(JSON.generate(value))
      end

      # Containers are deep-duplicated (they are JSON-pure after roundtrip);
      # scalars are safe to share.
      def dup_value(value)
        case value
        when Hash, Array then roundtrip(value)
        else value
        end
      end
    end
  end
end

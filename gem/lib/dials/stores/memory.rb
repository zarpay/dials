# frozen_string_literal: true

module Dials
  module Stores
    # The reference store: plain hashes behind a mutex. It is the default
    # store so the gem works out of the box (and in client test suites)
    # without a database, and it doubles as the executable specification of
    # the store interface:
    #
    #   state                                  → { globals:, variations:, version:, row_versions: }
    #   version                                → monotonic value, moves on every write
    #   override_version(key, canonical)       → the row's version stamp; 0 when absent
    #   set_global(key, value, actor, expected_version: nil)          → previous value or nil
    #   clear_global(key, actor, expected_version: nil)               → true if an override existed
    #   set_variation(key, canonical, value, actor, expected_version: nil) → previous value or nil
    #   clear_variation(key, canonical, actor, expected_version: nil) → true if a variation existed
    #   changes(key: nil, limit: 50)           → newest-first [ChangeRecord]
    #
    # `actor` is the normalized hash from Dials::Actor. Value validation and
    # scope validation happen above the store; a store only persists.
    #
    # Concurrency control is per-override optimistic locking: every stored
    # override carries a version stamp (here, the write counter at its last
    # write; in the ActiveRecord store, the change-log id — both monotonic
    # store-wide, so a row deleted and re-created never revisits a version).
    # `expected_version:` (an opaque StoreVersion token) compares against
    # THAT override's stamp — StoreVersion::ABSENT means "I saw no override
    # here" — atomically with the write; a mismatch raises StaleWrite with
    # nothing applied or logged. The check runs before the existence check on
    # clears: a no-op clear against a stale picture is still stale.
    #
    # Values are round-tripped through JSON on write, exactly like the
    # ActiveRecord store. That buys two guarantees at once: the store never
    # retains a reference to a caller-owned mutable object (mutating a hash
    # after a write cannot silently change the stored override or rewrite
    # change-log history), and both stores return byte-identical shapes
    # (symbol keys become strings here too, so a test suite on the memory
    # store proves what production on ActiveRecord will do).
    class Memory
      def initialize
        @globals = {}
        @variations = Hash.new { |h, k| h[k] = {} }
        @row_versions = Hash.new { |h, k| h[k] = {} }
        @changes = []
        @version = 0
        @mutex = Mutex.new
      end

      def state
        @mutex.synchronize do
          {
            globals: @globals.transform_values { |v| dup_value(v) },
            variations: @variations.to_h { |k, scopes| [k, scopes.transform_values { |v| dup_value(v) }] },
            version: @version,
            row_versions: @row_versions.to_h { |k, scopes| [k, scopes.dup] }
          }
        end
      end

      def version
        @mutex.synchronize { @version }
      end

      def override_version(key, canonical_scope)
        @mutex.synchronize { row_version(key, canonical_scope) }
      end

      def set_global(key, value, actor, expected_version: nil)
        @mutex.synchronize do
          assert_version!(expected_version, row_version(key, Scope::GLOBAL))
          stored = roundtrip(value)
          old = @globals[key]
          @globals[key] = stored
          record(key, nil, "set", old, stored, actor)
          stamp(key, Scope::GLOBAL)
          old
        end
      end

      def clear_global(key, actor, expected_version: nil)
        @mutex.synchronize do
          assert_version!(expected_version, row_version(key, Scope::GLOBAL))
          next false unless @globals.key?(key)

          old = @globals.delete(key)
          record(key, nil, "clear", old, nil, actor)
          unstamp(key, Scope::GLOBAL)
          true
        end
      end

      def set_variation(key, canonical_scope, value, actor, expected_version: nil)
        @mutex.synchronize do
          assert_version!(expected_version, row_version(key, canonical_scope))
          stored = roundtrip(value)
          old = @variations[key][canonical_scope]
          @variations[key][canonical_scope] = stored
          record(key, canonical_scope, "set", old, stored, actor)
          stamp(key, canonical_scope)
          old
        end
      end

      def clear_variation(key, canonical_scope, actor, expected_version: nil)
        @mutex.synchronize do
          assert_version!(expected_version, row_version(key, canonical_scope))
          next false unless @variations.key?(key) && @variations[key].key?(canonical_scope)

          old = @variations[key].delete(canonical_scope)
          @variations.delete(key) if @variations[key].empty?
          record(key, canonical_scope, "clear", old, nil, actor)
          unstamp(key, canonical_scope)
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

      # Callers hold the mutex.
      def row_version(key, canonical_scope)
        @row_versions[key][canonical_scope] || 0
      end

      # Callers hold the mutex. Raises StaleWrite before anything is touched,
      # so the transactionless memory store still guarantees "unapplied and
      # unlogged" on a version mismatch.
      def assert_version!(expected, current)
        return if expected.nil? || expected == StoreVersion.token(current)

        raise StaleWrite,
              "the override has changed since version #{expected} was read — " \
              "re-read (Dials.overview) and retry deliberately"
      end

      # Callers hold the mutex; record has already bumped @version, which
      # serves as the row stamp (the ActiveRecord analog is the change id).
      def stamp(key, canonical_scope)
        @row_versions[key][canonical_scope] = @version
      end

      def unstamp(key, canonical_scope)
        @row_versions[key].delete(canonical_scope)
        @row_versions.delete(key) if @row_versions[key].empty?
      end

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

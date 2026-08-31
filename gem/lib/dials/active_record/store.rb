# frozen_string_literal: true

module Dials
  module Stores
    # The production store: three ActiveRecord-backed tables (see
    # Dials::ActiveRecord::Setting / Variation / Change). Implements the same
    # interface as Stores::Memory; every mutation runs in a transaction with
    # its change-log row, so the version counter (max change id) can never
    # run ahead of or behind the data it stamps.
    class ActiveRecordStore
      Setting = Dials::ActiveRecord::Setting
      Variation = Dials::ActiveRecord::Variation
      Change = Dials::ActiveRecord::Change

      def state
        # Version first: if a write lands between these reads, the snapshot
        # carries an older version than its data, and the next probe sees the
        # version move and rebuilds — stale in the safe direction only.
        version = Change.maximum(:id) || 0

        globals = Setting.where.not(value: nil).pluck(:key, :value)
                         .to_h { |key, value| [key.to_sym, decode(value)] }

        variations = {}
        Variation.joins(:setting)
                 .pluck("#{Setting.table_name}.key", "#{Variation.table_name}.scope", "#{Variation.table_name}.value")
                 .each do |key, scope, value|
          (variations[key.to_sym] ||= {})[scope] = decode(value)
        end

        { globals: globals, variations: variations, version: version }
      end

      def version
        Change.maximum(:id) || 0
      end

      def set_global(key, value, actor)
        transaction_with_retry do
          setting = Setting.find_or_initialize_by(key: key.to_s)
          old = setting.value.nil? ? nil : decode(setting.value)
          setting.update!(value: encode(value))
          record(key, nil, "set", old, value, actor)
          old
        end
      end

      def clear_global(key, actor)
        Setting.transaction do
          setting = Setting.find_by(key: key.to_s)
          next false if setting.nil? || setting.value.nil?

          old = decode(setting.value)
          if setting.variations.exists?
            setting.update!(value: nil)
          else
            setting.destroy!
          end
          record(key, nil, "clear", old, nil, actor)
          true
        end
      end

      def set_variation(key, canonical_scope, value, actor)
        transaction_with_retry do
          setting = Setting.find_or_create_by!(key: key.to_s)
          variation = setting.variations.find_or_initialize_by(scope: canonical_scope)
          old = variation.persisted? ? decode(variation.value) : nil
          variation.update!(value: encode(value))
          record(key, canonical_scope, "set", old, value, actor)
          old
        end
      end

      def clear_variation(key, canonical_scope, actor)
        Setting.transaction do
          setting = Setting.find_by(key: key.to_s)
          variation = setting&.variations&.find_by(scope: canonical_scope)
          next false if variation.nil?

          old = decode(variation.value)
          variation.destroy!
          # A parent holding neither a global override nor any variation is
          # meaningless; remove it so "no overrides" and "no rows" stay
          # synonyms.
          setting.destroy! if setting.value.nil? && !setting.variations.exists?
          record(key, canonical_scope, "clear", old, nil, actor)
          true
        end
      end

      def changes(key: nil, limit: 50)
        relation = Change.order(id: :desc).limit(limit)
        relation = relation.where(key: key.to_s) if key
        relation.map do |row|
          ChangeRecord.new(
            key: row.key.to_sym,
            scope: row.scope && Scope.parse(row.scope),
            action: row.action,
            old_value: row.old_value.nil? ? nil : decode(row.old_value),
            new_value: row.new_value.nil? ? nil : decode(row.new_value),
            actor_type: row.actor_type,
            actor_id: row.actor_id,
            actor_label: row.actor_label,
            created_at: row.created_at
          )
        end
      end

      private

      def record(key, canonical_scope, action, old_value, new_value, actor)
        Change.create!(
          key: key.to_s,
          scope: canonical_scope,
          action: action,
          old_value: old_value.nil? ? nil : encode(old_value),
          new_value: new_value.nil? ? nil : encode(new_value),
          actor_type: actor[:actor_type],
          actor_id: actor[:actor_id],
          actor_label: actor[:actor_label]
        )
      end

      # Two processes creating the same parent row race on the unique key
      # index; the loser retries once and finds the winner's row.
      def transaction_with_retry(&)
        attempts = 0
        begin
          Setting.transaction(&)
        rescue ::ActiveRecord::RecordNotUnique
          attempts += 1
          retry if attempts == 1
          raise
        end
      end

      def encode(value)
        JSON.generate(value)
      end

      # Values round-trip through JSON, so a :json dial's hash keys come back
      # as strings — the same value a JSON API would hand you. Scalar types
      # (boolean, integer, float, string) round-trip exactly.
      def decode(raw)
        JSON.parse(raw)
      end
    end
  end
end

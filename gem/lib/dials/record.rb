# frozen_string_literal: true

require "active_record"
require "json"

module Dials
  # The one table.
  #
  # Every write appends a row; nothing is ever updated or deleted. A dial's
  # current value for a scope is the newest row for that `(key, scope)` pair,
  # and a row with a NULL value is a tombstone meaning "cleared — fall back to
  # the layer below".
  #
  # Append-only buys three things at once. The change log *is* the state, so
  # there is no second table to keep in step. Concurrent writers cannot
  # conflict, because an INSERT has nothing to race for — the higher id simply
  # wins, which is also the answer you want. And the row count is a monotonic
  # version counter, which is how a process notices writes made by another one.
  class Record < ::ActiveRecord::Base
    self.table_name = "dials"

    # Rows are facts. A persisted row is history and part of the version
    # counter; rewriting one would quietly rewrite the past.
    def readonly? = persisted?

    def scope_hash = Scope.load(self[:scope])
    def cleared? = self[:value].nil?
    def value = self[:value] && JSON.parse(self[:value], freeze: true)

    class << self
      # The newest row per (key, scope): the current state, tombstones included.
      def current = where(id: group(:key, :scope).select("MAX(id)"))

      # Everything currently overridden, in one query:
      #   { key(Symbol) => { scope(Hash) => value } }
      #
      # Values are frozen, because every reader in the process shares them.
      def overrides
        current.where.not(value: nil).pluck(:key, :scope, :value).each_with_object({}) do |(key, scope, value), out|
          (out[key.to_sym] ||= {})[Scope.load(scope)] = JSON.parse(value, freeze: true)
        end
      end

      # Moves on every write and never moves back — nothing is ever deleted —
      # so one cheap query tells a process whether its cache is still current.
      def version = count
    end
  end
end

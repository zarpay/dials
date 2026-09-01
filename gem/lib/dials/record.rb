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
  #
  # Every query against the table lives here, and so does both halves of the
  # `value` column's round trip — mirroring Scope, which owns both halves of
  # the `scope` column.
  class Record < ::ActiveRecord::Base
    self.table_name = "dials"

    # Rows are facts. A persisted row is history and part of the version
    # counter; rewriting one would quietly rewrite the past.
    def readonly? = persisted?

    def scope_hash = Scope.load(self[:scope])
    def cleared? = self[:value].nil?
    def value = Record.decode(self[:value])

    class << self
      def encode(value) = value.nil? ? nil : JSON.generate(value)

      # Frozen: every reader in the process shares the loaded snapshot.
      def decode(raw) = raw && JSON.parse(raw, freeze: true)

      # The newest row per (key, scope): the current state, tombstones included.
      def current = where(id: group(:key, :scope).select("MAX(id)"))

      # Everything currently overridden, in one query:
      #   { key(Symbol) => { scope(Hash) => value } }
      #
      # The tombstone filter runs on the OUTER query, after the fold — a
      # cleared row wins its group and is then dropped, so the scope falls
      # through to the layer below. Filtering inside the fold instead would let
      # the superseded row win, and a reset would resurrect what it cleared.
      def overrides
        current.where.not(value: nil).pluck(:key, :scope, :value).each_with_object({}) do |(key, scope, value), out|
          (out[key.to_sym] ||= {})[Scope.load(scope)] = decode(value)
        end
      end

      # The id of the row that last wrote one override, or 0 when none is
      # stored — the stale-write token behind Dial#version.
      def version_for(key, canonical_scope)
        where(key: key.to_s, scope: canonical_scope).maximum(:id) || 0
      end

      # The change log, newest first, for one dial or all of them. An Array
      # rather than a relation: history is a record of facts, and handing back a
      # relation would hand back `update_all` and `delete_all` over the one
      # table whose append-only shape every other guarantee rests on.
      def history(key: nil, limit: 50)
        rows = order(id: :desc).limit(limit)
        rows = rows.where(key: key.to_s) if key
        rows.to_a
      end

      # Moves on every write and never moves back — nothing is ever deleted —
      # so one cheap query tells a process whether its cache is still current.
      def version = count
    end
  end
end

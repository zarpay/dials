# Changelog

## [Unreleased]

## [0.1.0] - 2026-08-31

Initial release.

- Code-declared registry (`Dials.define` / `dial`) with types (boolean,
  integer, float, string, json), bounds (Range / Array / callable), labels,
  units, and descriptions.
- Variant dimensions per dial (`variants:`), validated options, exact-scope
  writes; resolution is variation → global override → code default with a
  most-specific-wins matcher already general enough for future partial
  scopes.
- Override semantics: the database stores overrides only; clearing an
  override returns resolution to the layer below.
- Per-process snapshot cache with throttled staleness probe (`cache_ttl`).
- Attributed writes: `Dials.set` / `Dials.clear` require `actor:`; every
  write lands in the append-only change log (`Dials.changes`).
- Stores: in-memory (default, zero-dependency) and ActiveRecord
  (`dials`, `dial_variations`, `dial_changes` tables; portable JSON-text
  columns).
- `rails g dials:install` generator (migration + initializer).
- `Dials::Testing.with_overrides` for client test suites.

# frozen_string_literal: true

require_relative "lib/dials/version"

Gem::Specification.new do |spec|
  spec.name = "dials"
  spec.version = Dials::VERSION
  spec.authors = ["Keith Gould"]
  spec.email = ["opensource@zarpay.app"]

  spec.summary = "Operator-adjustable values with per-scope overrides, attribution, and caching."
  spec.description = <<~TEXT
    Dials turns hardcoded constants into operator-adjustable values without
    giving up code review as the source of truth. Each dial is declared in
    code with a default, a type, JSON-Schema-style constraints, and optional
    dimensions (per market, per platform, ...); runtime overrides live in
    two small database tables, resolve scoped override → global override →
    code default, are served from a per-process cache, and every write is
    attributed in an append-only change log with optional stale-write
    protection.
  TEXT
  spec.homepage = "https://github.com/zarpay/dials"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.metadata = {
    "bug_tracker_uri" => "https://github.com/zarpay/dials/issues",
    "changelog_uri" => "https://github.com/zarpay/dials/blob/main/gem/CHANGELOG.md",
    "documentation_uri" => "https://zarpay.github.io/dials/",
    "source_code_uri" => "https://github.com/zarpay/dials/tree/main/gem"
  }

  # bin/console and bin/setup are development scripts, not user-facing
  # executables — packaging them would install `console` and `setup`
  # commands onto every user's PATH, so the gem ships lib/ only.
  spec.files = Dir.glob("lib/**/*", File::FNM_DOTMATCH).reject do |path|
    File.directory?(path) || path.include?("/.")
  end + %w[
    CHANGELOG.md
    LICENSE.txt
    README.md
  ]
  spec.require_paths = ["lib"]
end

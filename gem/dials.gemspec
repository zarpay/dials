# frozen_string_literal: true

require_relative "lib/dials/version"

Gem::Specification.new do |spec|
  spec.name = "dials"
  spec.version = Dials::VERSION
  spec.authors = ["Keith Gould"]
  spec.email = ["opensource@zarpay.app"]

  spec.summary = "Operator-adjustable values with per-variant overrides, attribution, and caching."
  spec.description = <<~TEXT
    Dials turns hardcoded constants into operator-adjustable values without
    giving up code review as the source of truth. Each dial is declared in
    code with a default, a type, bounds, and optional variant dimensions
    (per market, per platform, ...); runtime overrides live in three small
    database tables, resolve variation → global override → code default,
    are served from a per-process cache, and every write is attributed in
    an append-only change log.
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

  spec.files = Dir.glob("{bin,lib}/**/*", File::FNM_DOTMATCH).reject do |path|
    File.directory?(path) || path.include?("/.")
  end + %w[
    CHANGELOG.md
    Gemfile
    README.md
    Rakefile
    .rubocop.yml
  ]
  spec.bindir = "bin"
  spec.executables = ["console", "setup"]
  spec.require_paths = ["lib"]
end

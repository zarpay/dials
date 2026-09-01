# frozen_string_literal: true

require_relative "lib/dials/version"

Gem::Specification.new do |spec|
  spec.name = "dials"
  spec.version = Dials::VERSION
  spec.authors = ["Keith Gould"]
  spec.email = ["opensource@zarpay.app"]

  spec.summary = "Constants you can turn without a deploy."
  spec.description = <<~TEXT
    Dials turns hardcoded constants into operator-adjustable values without
    giving up code review as the source of truth. A dial is declared in code
    with a default, a type, and optionally the dimensions it may vary along
    (per market, per platform, ...). Overrides live in one append-only table
    that is the change log and the current state at the same time, resolve
    most-specific-scope-first, are served from a per-process cache, and carry
    the actor who made them.
  TEXT
  spec.homepage = "https://github.com/zarpay/dials"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"

  spec.add_dependency "activerecord", ">= 7.2"
  spec.add_dependency "literal", "~> 1.9"

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

# dials

[![CI](https://github.com/zarpay/dials/actions/workflows/ci.yml/badge.svg)](https://github.com/zarpay/dials/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/zarpay/dials)](https://github.com/zarpay/dials/blob/main/LICENSE.txt)
[![Ruby](https://img.shields.io/badge/Ruby-%3E%3D%203.2-red)](https://rubygems.org)

`dials` is a Ruby gem for operator-adjustable values: constants you can turn
without a deploy. A dial is declared in code with a default, a type,
JSON-Schema-style constraints, and optional dimensions (per market,
per platform, ...); runtime
overrides live in one small append-only table, resolve
**scoped override → global override → code default**, are served from a
per-process cache, and every write is attributed in an append-only change
log.

```ruby
Dials.define do
  dial :checkout_fee_bps, default: 250,
       type: :integer, minimum: 1, maximum: 10_000, unit: "bps",
       dimensions: { market: { enum: %w[KE NG BD] } }
end

Dials.checkout_fee_bps(market: "KE")                       # => 250
Dials.adjust_checkout_fee_bps(120, actor: admin, market: "BD")
Dials.checkout_fee_bps(market: "BD")                       # => 120
```

## Repository layout

This repo is organized as three top-level packages:

| Directory | Purpose | README |
|---|---|---|
| [`gem/`](./gem) | The published gem source — `lib/`, `test/`, gemspec, `CHANGELOG.md`. Everything that ends up on RubyGems lives here. | [`gem/README.md`](./gem/README.md) |
| [`docs/`](./docs) | The VitePress documentation site published to <https://zarpay.github.io/dials/>. | [`docs/`](./docs) |
| [`demo/`](./demo) | A Rails 8.1 app ("Bazario") that showcases every public feature; its spec suite proves out the gem's API against a real database. | [`demo/README.md`](./demo/README.md) |

## Working in this repo

Each package is independent and uses its own Gemfile / dependencies.

```bash
# work on the gem
cd gem
bundle install
bundle exec rake          # minitest + rubocop

# work on the docs site
cd docs
npm install
npm run dev               # local VitePress server

# work on the demo
cd demo
bundle install
bin/rails db:migrate && bin/rails db:migrate RAILS_ENV=test
bundle exec rspec         # runs the suite against ../gem
```

The demo's `Gemfile` path-pins `gem "dials", path: "../gem"`, so changes in
`gem/` are immediately picked up by `bundle exec rspec` in `demo/`. This
makes the demo a real-time integration check during gem development.

## CI

Three GitHub workflows live in `.github/workflows/`:

| Workflow | Triggers | What it does |
|---|---|---|
| `ci.yml` | push to `main`, every PR | Runs the gem's minitest suite across Ruby 3.2 – 3.4, the rubocop quality job, and the demo's full RSpec suite |
| `release.yml` | a published GitHub Release | Re-runs the gem suite on the tagged commit, then publishes to RubyGems.org via OIDC trusted publishing |
| `docs.yml` | push to `main` | Builds the VitePress site from `docs/` and deploys it to GitHub Pages |

## Contributing

- Bug or feature in the gem → PR against `gem/` (tests in `gem/test/`,
  `bundle exec rake` runs everything).
- Documentation → PR against `docs/` (`npm run build` must pass).
- New integration scenarios or app-level patterns → PR against `demo/`.

## Acknowledgments

Sebastian Scholl ([@sebscholl](https://github.com/sebscholl)) pushed for
extracting this functionality as a gem in the first place, advocated the
JSON Schema constraint vocabulary, and gave solid feedback on the early
design.

The append-only storage design ("the log is the state") and the bare-name
readers were adopted from an exploration by Stephen Margheim
([@fractaledmind](https://github.com/fractaledmind)) in
[PR #1](https://github.com/zarpay/dials/pull/1).

## License

[MIT](./LICENSE.txt).

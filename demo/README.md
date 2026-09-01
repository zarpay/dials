# dials demo — "Bazario"

A Rails 8 app whose test suite proves out the `dials` gem's public API
against a real database. The Gemfile path-pins `gem "dials", path: "../gem"`,
so this suite doubles as a live integration check while developing the gem.

Bazario is a fictional commerce platform in three markets (KE, NG, BD) across
three platforms (ios, android, web). Every file is annotated to teach one
part of the gem:

| File | Teaches |
|---|---|
| `config/initializers/dials.rb` | The registry: every declaration shape (types, constraints, one/two/open dimensions, a global-only kill switch) |
| `app/services/pricing/quote_service.rb` | The dial consumer: reads values for its context, never knows which layer they came from |
| `app/services/onboarding/signup_policy.rb` | The global-only kill switch pattern |
| `app/controllers/admin/dials_controller.rb` | The hand-built write surface (the gem ships no GUI): attribution, typed errors → HTTP statuses |
| `spec/dials/registry_spec.rb` | The registry-integrity pin: arming a dial with dimensions is a visible, reviewed diff |
| `spec/dials/resolution_spec.rb` | scoped override → global override → code default, layer by layer |
| `spec/dials/change_log_spec.rb` | Attributed, append-only history |
| `spec/dials/caching_spec.rb` | Own-writes-immediate, staleness probe, zero queries per read |
| `spec/services/**` | Consuming and testing dials in domain code (`Dials::Testing.with_overrides`) |
| `spec/requests/admin/dials_spec.rb` | The full HTTP write contract, including `false` over the wire |
| `spec/support/dials.rb` | The one line of test hygiene a client app needs |

## Running

```bash
bundle install
bin/rails db:migrate && bin/rails db:migrate RAILS_ENV=test
bundle exec rspec
```

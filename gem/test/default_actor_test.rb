# frozen_string_literal: true

require "test_helper"

class DefaultActorTest < Minitest::Test
  include DialsTestSupport

  def setup
    super
    define_standard_dials
  end

  def test_without_a_default_actor_is_required_exactly_as_before
    error = assert_raises(Dials::MissingActor) { Dials.adjust_signups_enabled(false) }
    assert_match(/default_actor/, error.message)
    assert_raises(Dials::MissingActor) { Dials.set(:signups_enabled, false, actor: nil) }
    assert_equal true, Dials.signups_enabled, "a refused write must change nothing"
  end

  def test_string_default_actor_attributes_writes_that_pass_no_actor
    Dials.configure { |c| c.default_actor = "anonymous" }
    Dials.adjust_signups_enabled(false)

    assert_equal false, Dials.signups_enabled
    change = Dials.changes.first
    assert_equal "anonymous", change.actor_label
    assert_nil change.actor_type
  end

  def test_callable_default_actor_is_evaluated_per_write
    calls = 0
    Dials.configure do |c|
      c.default_actor = lambda {
        calls += 1
        "operator-#{calls}"
      }
    end

    Dials.set(:signups_enabled, false, actor: nil)
    Dials.set(:signups_enabled, true, actor: nil)

    assert_equal %w[operator-2 operator-1], Dials.changes.map(&:actor_label)
  end

  def test_explicit_actor_always_wins_over_the_default
    Dials.configure { |c| c.default_actor = "anonymous" }
    Dials.set(:signups_enabled, false, actor: "keith — incident")

    assert_equal "keith — incident", Dials.changes.first.actor_label
  end

  def test_callable_default_returning_nil_still_raises_missing_actor
    Dials.configure { |c| c.default_actor = -> {} }
    assert_raises(Dials::MissingActor) { Dials.set(:signups_enabled, false, actor: nil) }
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../release_build_guard"

class ReleaseBuildGuardTest < Minitest::Test
  VALID_BUILD_NUMBERS = {
    "EXPECTED_PREVIOUS_BUILD_NUMBER" => "41",
    "EXPECTED_BUILD_NUMBER" => "42"
  }.freeze

  def test_accepts_consecutive_canonical_positive_build_numbers
    assert_nil ReleaseBuildGuard.validate!(previous_build: "41", build: "42")
    assert_nil ReleaseBuildGuard.validate!(previous_build: "1", build: "2")
  end

  def test_rejects_non_numeric_build_numbers
    VALID_BUILD_NUMBERS.each_key do |name|
      assert_invalid_build_number(name, "not-a-number")
    end
  end

  def test_rejects_zero_and_negative_build_numbers
    VALID_BUILD_NUMBERS.each_key do |name|
      ["0", "-1"].each do |invalid_build|
        assert_invalid_build_number(name, invalid_build)
      end
    end
  end

  def test_rejects_non_canonical_build_number_formats
    VALID_BUILD_NUMBERS.each_key do |name|
      ["+42", "042", "4 2", " 42", "42 "].each do |invalid_build|
        assert_invalid_build_number(name, invalid_build)
      end
    end
  end

  def test_rejects_a_build_that_is_not_the_previous_build_plus_one
    ["40", "41", "43"].each do |non_consecutive_build|
      error = assert_raises(ReleaseBuildGuard::InvalidExpectation) do
        ReleaseBuildGuard.validate!(previous_build: "41", build: non_consecutive_build)
      end

      assert_includes error.message, "EXPECTED_PREVIOUS_BUILD_NUMBER + 1"
    end
  end

  def test_allows_a_non_consecutive_build_only_with_explicit_flag_and_reason
    assert_nil ReleaseBuildGuard.validate!(
      previous_build: "243", build: "245", allow_intentional_gap: true, intentional_gap_reason: "244 local-only"
    )
    assert_raises(ReleaseBuildGuard::InvalidExpectation) do
      ReleaseBuildGuard.validate!(previous_build: "243", build: "245", allow_intentional_gap: true)
    end
    assert_raises(ReleaseBuildGuard::InvalidExpectation) do
      ReleaseBuildGuard.validate!(
        previous_build: "41", build: "43", allow_intentional_gap: true, intentional_gap_reason: "unrelated"
      )
    end
  end

  private

  def assert_invalid_build_number(name, value)
    builds = VALID_BUILD_NUMBERS.merge(name => value)

    error = assert_raises(ReleaseBuildGuard::InvalidExpectation) do
      ReleaseBuildGuard.validate!(
        previous_build: builds.fetch("EXPECTED_PREVIOUS_BUILD_NUMBER"),
        build: builds.fetch("EXPECTED_BUILD_NUMBER")
      )
    end

    assert_includes error.message, name
  end
end

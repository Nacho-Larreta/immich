# frozen_string_literal: true

module ReleaseBuildGuard
  CANONICAL_POSITIVE_DECIMAL = /\A[1-9][0-9]*\z/

  class InvalidExpectation < ArgumentError; end

  module_function

  def validate!(previous_build:, build:)
    previous_build_number = parse_build_number("EXPECTED_PREVIOUS_BUILD_NUMBER", previous_build)
    build_number = parse_build_number("EXPECTED_BUILD_NUMBER", build)

    return if build_number == previous_build_number + 1

    raise InvalidExpectation,
          "EXPECTED_BUILD_NUMBER must equal EXPECTED_PREVIOUS_BUILD_NUMBER + 1"
  end

  def parse_build_number(name, value)
    unless value.is_a?(String) && value.match?(CANONICAL_POSITIVE_DECIMAL)
      raise InvalidExpectation, "#{name} must be a canonical positive decimal integer"
    end

    value.to_i
  end
  private_class_method :parse_build_number
end

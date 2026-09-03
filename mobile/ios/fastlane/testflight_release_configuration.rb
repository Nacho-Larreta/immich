# frozen_string_literal: true

require_relative "release_build_guard"

module TestFlightReleaseConfiguration
  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
  KEY_TYPES = %w[team individual].freeze

  class InvalidConfiguration < ArgumentError; end

  class ApiKey
    attr_reader :key_type, :key_id, :key_path, :issuer_id

    def self.from_env(env)
      key_type = required(env, "ASC_KEY_TYPE")
      key_id = required(env, "ASC_KEY_ID")
      key_path = required(env, "ASC_KEY_PATH")
      issuer_value = required(env, "ASC_ISSUER_ID")

      unless KEY_TYPES.include?(key_type)
        raise InvalidConfiguration, "ASC_KEY_TYPE must be team or individual"
      end

      issuer_id = issuer_for(key_type, issuer_value)
      new(key_type: key_type, key_id: key_id, key_path: key_path, issuer_id: issuer_id)
    end

    def initialize(key_type:, key_id:, key_path:, issuer_id:)
      @key_type = key_type.freeze
      @key_id = key_id.freeze
      @key_path = key_path.freeze
      @issuer_id = issuer_id&.freeze
      freeze
    end

    def team?
      key_type == "team"
    end

    def fastlane_options
      {
        key_id: key_id,
        issuer_id: issuer_id,
        key_filepath: key_path,
        duration: 1200,
        in_house: false
      }.freeze
    end

    def inspect
      "#<#{self.class.name} key_type=#{key_type}>"
    end

    class << self
      private

      def required(env, name)
        value = env[name]
        raise InvalidConfiguration, "#{name} must be set explicitly" unless value.is_a?(String) && !value.strip.empty?

        value.strip
      end

      def issuer_for(key_type, value)
        if key_type == "individual"
          raise InvalidConfiguration, "ASC_ISSUER_ID must be none for an individual key" unless value == "none"

          return nil
        end

        raise InvalidConfiguration, "ASC_ISSUER_ID must be a UUID for a team key" unless value.match?(UUID)

        value
      end
    end
  end

  class Release
    REQUIRED_NAMES = %w[
      ASC_TEAM_ID
      DEVELOPER_PORTAL_TEAM_ID
      TESTFLIGHT_INTERNAL_GROUP
      TESTFLIGHT_TESTER_EMAIL_1
      TESTFLIGHT_TESTER_EMAIL_2
      EXPECTED_VERSION
      EXPECTED_PREVIOUS_BUILD_NUMBER
      EXPECTED_BUILD_NUMBER
      IPA_PATH
    ].freeze

    attr_reader :asc_team_id,
                :developer_portal_team_id,
                :bundle_id,
                :group_name,
                :tester_emails,
                :version,
                :previous_build_number,
                :build_number,
                :allow_intentional_build_gap,
                :intentional_build_gap_reason,
                :ipa_path

    def self.from_env(env, bundle_id:)
      values = REQUIRED_NAMES.each_with_object({}) do |name, result|
        value = env[name]
        raise InvalidConfiguration, "#{name} must be set explicitly" unless value.is_a?(String) && !value.strip.empty?

        result[name] = value.strip
      end

      emails = [values.fetch("TESTFLIGHT_TESTER_EMAIL_1"), values.fetch("TESTFLIGHT_TESTER_EMAIL_2")]
      if emails.map(&:downcase).uniq.length != 2
        raise InvalidConfiguration, "TESTFLIGHT_TESTER_EMAIL_1 and TESTFLIGHT_TESTER_EMAIL_2 must be distinct"
      end

      begin
        ReleaseBuildGuard.validate!(
          previous_build: values.fetch("EXPECTED_PREVIOUS_BUILD_NUMBER"),
          build: values.fetch("EXPECTED_BUILD_NUMBER"),
          allow_intentional_gap: env["TESTFLIGHT_ALLOW_INTENTIONAL_BUILD_GAP"] == "true",
          intentional_gap_reason: env["TESTFLIGHT_INTENTIONAL_BUILD_GAP_REASON"]
        )
      rescue ReleaseBuildGuard::InvalidExpectation => error
        raise InvalidConfiguration, error.message
      end

      new(
        asc_team_id: values.fetch("ASC_TEAM_ID"),
        developer_portal_team_id: values.fetch("DEVELOPER_PORTAL_TEAM_ID"),
        bundle_id: required_bundle_id(bundle_id),
        group_name: values.fetch("TESTFLIGHT_INTERNAL_GROUP"),
        tester_emails: emails,
        version: values.fetch("EXPECTED_VERSION"),
        previous_build_number: values.fetch("EXPECTED_PREVIOUS_BUILD_NUMBER"),
        build_number: values.fetch("EXPECTED_BUILD_NUMBER"),
        allow_intentional_build_gap: env["TESTFLIGHT_ALLOW_INTENTIONAL_BUILD_GAP"] == "true",
        intentional_build_gap_reason: env["TESTFLIGHT_INTENTIONAL_BUILD_GAP_REASON"],
        ipa_path: values.fetch("IPA_PATH")
      )
    end

    def initialize(**values)
      values.each { |name, value| instance_variable_set("@#{name}", freeze_value(value)) }
      freeze
    end

    def inspect
      "#<#{self.class.name} version=#{version} previous_build_number=#{previous_build_number} build_number=#{build_number}>"
    end

    class << self
      private

      def required_bundle_id(bundle_id)
        raise InvalidConfiguration, "bundle_id must be set explicitly" unless bundle_id.is_a?(String) && !bundle_id.strip.empty?

        bundle_id.strip
      end
    end

    private

    def freeze_value(value)
      return value.map { |item| item.dup.freeze }.freeze if value.is_a?(Array)

      value.dup.freeze
    end
  end
end

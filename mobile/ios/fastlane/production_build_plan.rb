# frozen_string_literal: true

require "pathname"
require_relative "release_build_guard"

module ProductionBuildPlan
  class InvalidPlan < ArgumentError; end

  Profile = Struct.new(:target, :bundle_id_suffix, :bundle_id, :path, keyword_init: true) do
    def initialize(**values)
      super(**values.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value })
      freeze
    end

    def inspect
      "#<#{self.class.name || 'ProductionBuildPlan::Profile'} target=#{target}>"
    end
  end

  SigningInputs = Struct.new(
    :developer_portal_team_id,
    :keychain_name,
    :signing_certificate_sha256,
    :profiles,
    keyword_init: true
  ) do
    def initialize(**values)
      super(**values.transform_values { |value| value.is_a?(String) ? value.dup.freeze : value })
      self.profiles = profiles.dup.freeze
      freeze
    end
  end

  class Plan
    DEVELOPER_PORTAL_TEAM_ID = "32NS8MR6UA"
    SEMANTIC_VERSION = /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/
    BUNDLE_ID = /\A[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+\z/
    KEYCHAIN_NAME = /\A[^\x00-\x1f\x7f]+\z/
    CERTIFICATE_SHA256 = /\A[0-9a-f]{64}\z/
    PROFILE_ENV = [
      ["RUNNER_PROFILE_PATH", "Runner", ""],
      ["SHARE_EXTENSION_PROFILE_PATH", "ShareExtension", ".ShareExtension"],
      ["WIDGET_EXTENSION_PROFILE_PATH", "WidgetExtension", ".WidgetExtension"]
    ].map { |entry| entry.map(&:freeze).freeze }.freeze
    REQUIRED_ENV_NAMES = (
      %w[
        EXPECTED_VERSION
        EXPECTED_PREVIOUS_BUILD_NUMBER
        EXPECTED_BUILD_NUMBER
        IPA_PATH
        ARCHIVE_PATH
        DEVELOPER_PORTAL_TEAM_ID
        KEYCHAIN_NAME
        SIGNING_CERTIFICATE_SHA256
      ] + PROFILE_ENV.map(&:first)
    ).map(&:freeze).freeze

    attr_reader :version,
                :previous_build_number,
                :build_number,
                :ipa_path,
                :archive_path,
                :developer_portal_team_id,
                :keychain_name,
                :signing_certificate_sha256,
                :profiles,
                :provisioning_profiles

    def self.from_env(env, bundle_id:)
      values = REQUIRED_ENV_NAMES.each_with_object({}) do |name, result|
        result[name] = required(env, name)
      end
      validate_version(values.fetch("EXPECTED_VERSION"))
      validate_build_numbers(values)
      ipa_path = validate_destination(values.fetch("IPA_PATH"), name: "IPA_PATH", extension: ".ipa")
      archive_path = validate_destination(
        values.fetch("ARCHIVE_PATH"),
        name: "ARCHIVE_PATH",
        extension: ".xcarchive"
      )
      signing_inputs = signing_inputs_from_env(env, bundle_id: bundle_id)

      new(
        version: values.fetch("EXPECTED_VERSION"),
        previous_build_number: values.fetch("EXPECTED_PREVIOUS_BUILD_NUMBER"),
        build_number: values.fetch("EXPECTED_BUILD_NUMBER"),
        ipa_path: ipa_path,
        archive_path: archive_path,
        developer_portal_team_id: signing_inputs.developer_portal_team_id,
        keychain_name: signing_inputs.keychain_name,
        signing_certificate_sha256: signing_inputs.signing_certificate_sha256,
        profiles: signing_inputs.profiles
      )
    end

    def self.signing_inputs_from_env(env, bundle_id:)
      names = %w[DEVELOPER_PORTAL_TEAM_ID KEYCHAIN_NAME SIGNING_CERTIFICATE_SHA256] + PROFILE_ENV.map(&:first)
      values = names.each_with_object({}) { |name, result| result[name] = required(env, name) }
      validated_bundle_id = validate_bundle_id(bundle_id)
      validate_team(values.fetch("DEVELOPER_PORTAL_TEAM_ID"))
      validate_keychain_name(values.fetch("KEYCHAIN_NAME"))
      validate_fingerprint(values.fetch("SIGNING_CERTIFICATE_SHA256"))

      SigningInputs.new(
        developer_portal_team_id: values.fetch("DEVELOPER_PORTAL_TEAM_ID"),
        keychain_name: values.fetch("KEYCHAIN_NAME"),
        signing_certificate_sha256: values.fetch("SIGNING_CERTIFICATE_SHA256"),
        profiles: build_profiles(values, validated_bundle_id)
      )
    end

    def initialize(version:, previous_build_number:, build_number:, ipa_path:, archive_path:,
                   developer_portal_team_id:, keychain_name:, signing_certificate_sha256:, profiles:)
      @version = frozen_copy(version)
      @previous_build_number = frozen_copy(previous_build_number)
      @build_number = frozen_copy(build_number)
      @ipa_path = frozen_copy(ipa_path)
      @archive_path = frozen_copy(archive_path)
      @developer_portal_team_id = frozen_copy(developer_portal_team_id)
      @keychain_name = frozen_copy(keychain_name)
      @signing_certificate_sha256 = frozen_copy(signing_certificate_sha256)
      @profiles = profiles.dup.freeze
      @provisioning_profiles = profiles.each_with_object({}) do |profile, result|
        result[profile.bundle_id] = profile.path
      end.freeze
      freeze
    end

    def inspect
      "#<#{self.class.name} profile_count=#{profiles.length} redacted>"
    end

    class << self
      private

      def required(env, name)
        value = env[name]
        unless value.is_a?(String) && !value.empty? && value == value.strip
          raise InvalidPlan, "#{name} must be set explicitly without surrounding whitespace"
        end

        value
      end

      def validate_bundle_id(bundle_id)
        unless bundle_id.is_a?(String) && bundle_id.match?(BUNDLE_ID) && bundle_id == bundle_id.strip
          raise InvalidPlan, "bundle_id must be an explicit valid bundle identifier"
        end

        bundle_id
      end

      def validate_version(version)
        return if version.match?(SEMANTIC_VERSION)

        raise InvalidPlan, "EXPECTED_VERSION must be a canonical three-part semantic version"
      end

      def validate_build_numbers(values)
        ReleaseBuildGuard.validate!(
          previous_build: values.fetch("EXPECTED_PREVIOUS_BUILD_NUMBER"),
          build: values.fetch("EXPECTED_BUILD_NUMBER")
        )
      rescue ReleaseBuildGuard::InvalidExpectation => error
        raise InvalidPlan, error.message
      end

      def validate_team(team_id)
        return if team_id == DEVELOPER_PORTAL_TEAM_ID

        raise InvalidPlan, "DEVELOPER_PORTAL_TEAM_ID does not match the production team"
      end

      def validate_keychain_name(keychain_name)
        return if keychain_name.match?(KEYCHAIN_NAME)

        raise InvalidPlan, "KEYCHAIN_NAME must be a nonempty single-line value"
      end

      def validate_fingerprint(fingerprint)
        return if fingerprint.match?(CERTIFICATE_SHA256)

        raise InvalidPlan, "SIGNING_CERTIFICATE_SHA256 must be exactly 64 lowercase hexadecimal characters"
      end

      def validate_destination(path, name:, extension:)
        pathname = Pathname.new(path)
        unless pathname.absolute? && pathname.cleanpath.to_s == path && pathname.extname == extension
          raise InvalidPlan, "#{name} must be an absolute canonical #{extension} destination"
        end
        if File.exist?(path) || File.symlink?(path)
          raise InvalidPlan, "#{name} destination must be absent"
        end

        validate_private_parent(pathname.parent, name)
        path
      rescue InvalidPlan
        raise
      rescue SystemCallError, ArgumentError
        raise InvalidPlan, "#{name} parent must be an accessible existing private directory"
      end

      def validate_private_parent(parent, name)
        stat = File.lstat(parent)
        valid = stat.directory? && !stat.symlink? && stat.uid == Process.euid &&
                stat.mode & 0o077 == 0 && stat.mode & 0o300 == 0o300
        return if valid

        raise InvalidPlan, "#{name} parent must be a private owned non-symlink directory"
      end

      def build_profiles(values, bundle_id)
        profiles = PROFILE_ENV.map do |name, target, suffix|
          path = validate_profile(values.fetch(name), name)
          Profile.new(
            target: target,
            bundle_id_suffix: suffix,
            bundle_id: "#{bundle_id}#{suffix}",
            path: path
          )
        end
        unless profiles.map(&:path).uniq.length == PROFILE_ENV.length
          raise InvalidPlan, "Provisioning profile paths must identify three distinct files"
        end

        profiles.freeze
      end

      def validate_profile(path, name)
        pathname = Pathname.new(path)
        unless pathname.absolute? && pathname.cleanpath.to_s == path && pathname.extname == ".mobileprovision"
          raise InvalidPlan, "#{name} must be an absolute canonical provisioning profile path"
        end

        stat = File.lstat(path)
        valid = stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.euid &&
                stat.mode & 0o077 == 0 && stat.mode & 0o400 != 0
        return path if valid

        raise InvalidPlan, "#{name} must be an existing private owned regular non-symlink file"
      rescue InvalidPlan
        raise
      rescue SystemCallError, ArgumentError
        raise InvalidPlan, "#{name} must be an accessible existing private regular file"
      end
    end

    private

    def frozen_copy(value)
      value.dup.freeze
    end
  end
end

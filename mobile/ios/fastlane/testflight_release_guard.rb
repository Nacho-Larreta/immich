# frozen_string_literal: true

require "time"
require_relative "release_build_guard"
require_relative "testflight_gateway_errors"

module TestFlightReleaseGuard
  ELIGIBLE_ROLES = %w[ACCOUNT_HOLDER ADMIN APP_MANAGER DEVELOPER MARKETING].freeze
  RETRY_BUILD_STATES = %w[PROCESSING].freeze
  ADVANCE_BUILD_STATES = %w[VALID].freeze
  FAIL_BUILD_STATES = %w[FAILED INVALID].freeze
  RETRY_INTERNAL_STATES = [nil, "PROCESSING", "IN_EXPORT_COMPLIANCE_REVIEW"].freeze
  ADVANCE_INTERNAL_STATES = %w[READY_FOR_BETA_TESTING IN_BETA_TESTING].freeze
  FAIL_INTERNAL_STATES = %w[MISSING_EXPORT_COMPLIANCE PROCESSING_EXCEPTION EXPIRED].freeze

  class Error < StandardError; end
  class PreflightFailure < Error; end
  class FinalizationFailure < Error; end
  class FinalizationTimeout < Error; end

  class FrozenDto < Struct
    def initialize(*values, **keywords)
      super
      each_pair do |name, value|
        self[name] = value.map { |item| item.is_a?(String) ? item.dup.freeze : item }.freeze if value.is_a?(Array)
        self[name] = value.dup.freeze if value.is_a?(String)
        self[name] = value.dup.freeze if value.is_a?(Time)
      end
      freeze
    end

    def inspect
      "#<#{self.class.name || 'TestFlightReleaseGuard::Dto'} redacted>"
    end
  end

  App = FrozenDto.new(:id, :bundle_id, keyword_init: true)
  Group = FrozenDto.new(:id, :app_id, :name, :internal, keyword_init: true)
  User = FrozenDto.new(:id, :email, :roles, :app_ids, :all_apps_access, keyword_init: true)
  BetaTester = FrozenDto.new(:id, :app_id, :email, :invite_type, :group_ids, keyword_init: true)
  Build = FrozenDto.new(
    :id,
    :app_id,
    :version,
    :build_number,
    :processing_state,
    :internal_state,
    :expired,
    :expiration_date,
    :uses_non_exempt_encryption,
    :group_ids,
    keyword_init: true
  )
  PreflightResult = FrozenDto.new(
    :remote_latest_build_number,
    :eligible_tester_count,
    :app_id,
    :group_id,
    keyword_init: true
  )
  FinalizationResult = FrozenDto.new(
    :build_number,
    :processing_state,
    :internal_state,
    :expiration_date,
    :eligible_tester_count,
    :group_associated,
    keyword_init: true
  )

  class Guard
    def initialize(gateway:, clock:, sleeper:, logger:)
      @gateway = gateway
      @clock = clock
      @sleeper = sleeper
      @logger = logger
    end

    def preflight(release)
      validate_build_expectation!(release)
      app = exact_app(release.bundle_id)
      group = exact_group(app.id, release.group_name)
      eligible_tester_count = verify_testers!(release.tester_emails, app.id, group.id)
      remote_latest = verify_remote_build_expectation!(release, app.id)

      log(
        :testflight_preflight_complete,
        remote_latest_build_number: remote_latest,
        eligible_tester_count: eligible_tester_count,
        exact_app: true,
        exact_group: true
      )
      PreflightResult.new(
        remote_latest_build_number: remote_latest,
        eligible_tester_count: eligible_tester_count,
        app_id: app.id,
        group_id: group.id
      )
    end

    def finalize(release, timeout_seconds:, poll_interval_seconds:)
      validate_polling!(timeout_seconds, poll_interval_seconds)
      app = exact_app(release.bundle_id)
      group = exact_group(app.id, release.group_name)
      verify_testers!(release.tester_emails, app.id, group.id)
      started_at = @clock.monotonic_now
      build = wait_until_releasable!(release, app.id, started_at, timeout_seconds, poll_interval_seconds)

      associate_group_if_missing!(build, group.id)
      verified_build = exact_uploaded_build(release, app.id)
      verify_releasable_build!(verified_build)
      unless verified_build.group_ids.include?(group.id)
        raise FinalizationFailure, "Build-to-group relationship was not verified"
      end

      tester_count = verify_testers!(release.tester_emails, app.id, group.id)
      log(
        :testflight_finalization_complete,
        build_number: verified_build.build_number,
        processing_state: verified_build.processing_state,
        internal_state: verified_build.internal_state,
        eligible_tester_count: tester_count,
        group_associated: true,
        expired: false,
        uses_non_exempt_encryption: false
      )
      FinalizationResult.new(
        build_number: verified_build.build_number,
        processing_state: verified_build.processing_state,
        internal_state: verified_build.internal_state,
        expiration_date: verified_build.expiration_date,
        eligible_tester_count: tester_count,
        group_associated: true
      )
    end

    private

    def validate_build_expectation!(release)
      ReleaseBuildGuard.validate!(
        previous_build: release.previous_build_number,
        build: release.build_number,
        allow_intentional_gap: release.allow_intentional_build_gap,
        intentional_gap_reason: release.intentional_build_gap_reason
      )
    rescue ReleaseBuildGuard::InvalidExpectation => error
      raise PreflightFailure, error.message
    end

    def exact_app(bundle_id)
      apps = @gateway.apps(bundle_id: bundle_id)
      raise PreflightFailure, "Expected exactly one App Store Connect app" unless apps.length == 1

      apps.first
    end

    def exact_group(app_id, name)
      groups = @gateway.internal_groups(app_id: app_id, name: name)
      unless groups.length == 1 && groups.first.internal
        raise PreflightFailure, "Expected exactly one internal TestFlight group"
      end

      groups.first
    end

    def verify_testers!(emails, app_id, group_id)
      raise PreflightFailure, "Exactly two distinct tester emails are required" unless emails.length == 2 && emails.map(&:downcase).uniq.length == 2

      emails.each do |email|
        users = @gateway.users(email: email)
        raise PreflightFailure, "Each tester must resolve to exactly one App Store Connect user" unless users.length == 1

        user = users.first
        unless eligible_role?(user) && eligible_app_access?(user, app_id)
          raise PreflightFailure, "Each tester requires an eligible role and app access"
        end

        testers = @gateway.beta_testers(app_id: app_id, email: email)
        unless testers.length == 1 && eligible_tester?(testers.first, group_id)
          raise PreflightFailure, "Each user must be an internal beta tester in the exact group"
        end
      end
      emails.length
    end

    def eligible_role?(user)
      !(user.roles & ELIGIBLE_ROLES).empty?
    end

    def eligible_app_access?(user, app_id)
      user.all_apps_access || user.app_ids.include?(app_id)
    end

    def eligible_tester?(tester, group_id)
      tester.group_ids.include?(group_id)
    end

    def verify_remote_build_expectation!(release, app_id)
      builds = @gateway.builds(app_id: app_id, version: release.version)
      numbers = builds.map { |build| canonical_build_number!(build.build_number) }
      if numbers.empty? || numbers.uniq.length != numbers.length
        raise PreflightFailure, "Remote build set must be non-empty and unambiguous"
      end

      remote_latest = builds.max_by { |build| build.build_number.to_i }.build_number
      unless remote_latest == release.previous_build_number && !numbers.include?(release.build_number.to_i)
        raise PreflightFailure, "Remote latest build does not match the exact release expectation"
      end

      remote_latest
    end

    def canonical_build_number!(number)
      unless number.is_a?(String) && number.match?(ReleaseBuildGuard::CANONICAL_POSITIVE_DECIMAL)
        raise PreflightFailure, "Remote build number is not a canonical positive decimal integer"
      end

      number.to_i
    end

    def wait_until_releasable!(release, app_id, started_at, timeout_seconds, poll_interval_seconds)
      loop do
        raise FinalizationTimeout, "TestFlight finalization timed out; rerun the finalizer" if timed_out?(started_at, timeout_seconds)

        build = exact_uploaded_build(release, app_id)
        state_decision = build_state_decision(build.processing_state)
        internal_decision = internal_state_decision(build.internal_state) if state_decision == :advance

        if state_decision == :advance && internal_decision == :advance
          verify_releasable_build!(build)
          return build
        end

        log(
          :testflight_processing_retry,
          build_number: build.build_number,
          processing_state: build.processing_state,
          internal_state: build.internal_state
        )
        @sleeper.sleep(poll_interval_seconds)
      end
    end

    def exact_uploaded_build(release, app_id)
      exact = @gateway.builds(app_id: app_id, version: release.version).select do |build|
        build.build_number == release.build_number
      end
      raise FinalizationFailure, "Expected exactly one uploaded build" unless exact.length == 1

      exact.first
    end

    def build_state_decision(state)
      return :retry if RETRY_BUILD_STATES.include?(state)
      return :advance if ADVANCE_BUILD_STATES.include?(state)

      description = FAIL_BUILD_STATES.include?(state) ? "terminal" : "unknown"
      raise FinalizationFailure, "Build processing state is #{description}"
    end

    def internal_state_decision(state)
      return :retry if RETRY_INTERNAL_STATES.include?(state)
      return :advance if ADVANCE_INTERNAL_STATES.include?(state)

      description = FAIL_INTERNAL_STATES.include?(state) ? "terminal" : "unknown"
      raise FinalizationFailure, "Internal beta state is #{description}"
    end

    def verify_releasable_build!(build)
      unless build_state_decision(build.processing_state) == :advance &&
             internal_state_decision(build.internal_state) == :advance
        raise FinalizationFailure, "Build is not releasable after the final refetch"
      end
      raise FinalizationFailure, "Build is expired" unless build.expired == false
      unless build.expiration_date.is_a?(Time) && build.expiration_date > @clock.now
        raise FinalizationFailure, "Build expiration date must be in the future"
      end
      unless build.uses_non_exempt_encryption == false
        raise FinalizationFailure, "Build encryption declaration must be resolved before finalization"
      end
    end

    def associate_group_if_missing!(build, group_id)
      return if build.group_ids.include?(group_id)

      @gateway.associate_build_to_group(build_id: build.id, group_id: group_id)
    rescue TestFlightConnectApiGateway::Conflict, TestFlightConnectApiGateway::AmbiguousMutation
      nil
    end

    def validate_polling!(timeout_seconds, poll_interval_seconds)
      unless timeout_seconds.is_a?(Numeric) && timeout_seconds.positive?
        raise FinalizationFailure, "timeout_seconds must be positive"
      end
      unless poll_interval_seconds.is_a?(Numeric) && poll_interval_seconds.positive? && poll_interval_seconds <= timeout_seconds
        raise FinalizationFailure, "poll_interval_seconds must be positive and bounded by timeout_seconds"
      end
    end

    def timed_out?(started_at, timeout_seconds)
      @clock.monotonic_now - started_at >= timeout_seconds
    end

    def log(event, evidence)
      @logger.info(event, evidence.freeze)
    end
  end
end

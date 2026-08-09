# frozen_string_literal: true

require "minitest/autorun"
require "time"
require_relative "../testflight_release_guard"

class TestFlightReleaseGuardTest < Minitest::Test
  Release = Struct.new(
    :bundle_id,
    :version,
    :previous_build_number,
    :build_number,
    :group_name,
    :tester_emails,
    keyword_init: true
  )

  class FakeClock
    attr_accessor :monotonic, :wall

    def initialize
      @monotonic = 10.0
      @wall = Time.utc(2026, 8, 9, 12)
    end

    def monotonic_now
      monotonic
    end

    def now
      wall
    end
  end

  class FakeSleeper
    attr_reader :durations

    def initialize(clock)
      @clock = clock
      @durations = []
    end

    def sleep(seconds)
      durations << seconds
      @clock.monotonic += seconds
    end
  end

  class FakeLogger
    attr_reader :events

    def initialize
      @events = []
    end

    def info(event, evidence)
      events << [event, evidence]
    end
  end

  class FakeGateway
    attr_accessor :users_by_email, :testers_by_email, :build_snapshots
    attr_reader :associations

    def initialize(app:, group:, users:, testers:, builds:)
      @app_records = [app]
      @group_records = [group]
      @users_by_email = users.group_by(&:email)
      @testers_by_email = testers.group_by(&:email)
      @build_snapshots = builds.map { |build| [build] }
      @associations = 0
      @association_error = nil
    end

    def apps(bundle_id:)
      @app_records.select { |app| app.bundle_id == bundle_id }
    end

    def internal_groups(app_id:, name:)
      @group_records.select { |group| group.app_id == app_id && group.name == name }
    end

    def duplicate_app
      @app_records << @app_records.first
    end

    def duplicate_group
      @group_records << @group_records.first
    end

    def users(email:)
      users_by_email.fetch(email, [])
    end

    def beta_testers(app_id:, email:)
      testers_by_email.fetch(email, []).select { |tester| tester.app_id == app_id }
    end

    def builds(app_id:, version:)
      snapshot = build_snapshots.length > 1 ? build_snapshots.shift : build_snapshots.first
      snapshot.select { |build| build.app_id == app_id && build.version == version }
    end

    def fail_association_with(error)
      @association_error = error
    end

    def associate_build_to_group(build_id:, group_id:)
      @associations += 1
      raise @association_error if @association_error

      build_snapshots.each do |snapshot|
        snapshot.map! do |build|
          next build unless build.id == build_id

          TestFlightReleaseGuard::Build.new(
            **build.to_h.merge(group_ids: (build.group_ids + [group_id]).uniq)
          )
        end
      end
    end
  end

  def setup
    @app = TestFlightReleaseGuard::App.new(id: "app-resource", bundle_id: "com.nacholarreta.nachofotos")
    @group = TestFlightReleaseGuard::Group.new(id: "group-resource", app_id: @app.id, name: "Private Family", internal: true)
    @users = [
      eligible_user("one@example.test"),
      eligible_user("two@example.test")
    ]
    @testers = [
      eligible_tester("one@example.test"),
      eligible_tester("two@example.test")
    ]
    @release = Release.new(
      bundle_id: @app.bundle_id,
      version: "1.142.0",
      previous_build_number: "41",
      build_number: "42",
      group_name: @group.name,
      tester_emails: @users.map(&:email)
    )
    @clock = FakeClock.new
    @sleeper = FakeSleeper.new(@clock)
    @logger = FakeLogger.new
  end

  def test_preflight_accepts_exact_app_group_remote_previous_build_and_two_eligible_testers
    guard, = guard_with([build(number: "41")])

    result = guard.preflight(@release)

    assert_equal "41", result.remote_latest_build_number
    assert_equal 2, result.eligible_tester_count
    assert result.frozen?
  end

  def test_preflight_accepts_internal_group_membership_without_beta_tester_state
    guard, = guard_with([build(number: "41")])

    result = guard.preflight(@release)

    assert_equal 2, result.eligible_tester_count
    refute_respond_to @testers.first, :state
  end

  def test_preflight_fails_closed_on_ambiguous_or_drifted_remote_state
    mutations = [
      ->(gateway) { gateway.duplicate_app },
      ->(gateway) { gateway.duplicate_group },
      ->(gateway) { gateway.users_by_email[@users.first.email] << @users.first },
      ->(gateway) { gateway.testers_by_email[@testers.first.email] << @testers.first },
      ->(gateway) { gateway.build_snapshots = [[build(number: "40")]] },
      ->(gateway) { gateway.build_snapshots = [[build(number: "41"), build(number: "42")]] }
    ]

    mutations.each do |mutate|
      guard, gateway = guard_with([build(number: "41")])
      mutate.call(gateway)
      assert_raises(TestFlightReleaseGuard::PreflightFailure) { guard.preflight(@release) }
    end
  end

  def test_preflight_rejects_ineligible_roles_app_access_and_group_membership
    invalid_users = [
      eligible_user(@users.first.email, roles: ["FINANCE"]),
      eligible_user(@users.first.email, app_ids: ["another-app"])
    ]
    invalid_testers = [eligible_tester(@testers.first.email, group_ids: [])]

    invalid_users.each do |user|
      guard, gateway = guard_with([build(number: "41")])
      gateway.users_by_email[user.email] = [user]
      assert_raises(TestFlightReleaseGuard::PreflightFailure) { guard.preflight(@release) }
    end
    invalid_testers.each do |tester|
      guard, gateway = guard_with([build(number: "41")])
      gateway.testers_by_email[tester.email] = [tester]
      assert_raises(TestFlightReleaseGuard::PreflightFailure) { guard.preflight(@release) }
    end
  end

  def test_finalizer_retries_only_allowlisted_processing_states_then_advances
    processing = build(number: "42", processing: "PROCESSING", internal: nil)
    compliance_review = build(number: "42", processing: "VALID", internal: "IN_EXPORT_COMPLIANCE_REVIEW")
    ready = build(number: "42", processing: "VALID", internal: "READY_FOR_BETA_TESTING")
    guard, gateway = guard_with([processing, compliance_review, ready])

    result = guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)

    assert_equal 1, gateway.associations
    assert_equal 2, result.eligible_tester_count
    assert_equal [5, 5], @sleeper.durations
  end

  def test_finalizer_retries_every_allowlisted_internal_state
    [nil, "PROCESSING", "IN_EXPORT_COMPLIANCE_REVIEW"].each do |state|
      guard, = guard_with([
        build(number: "42", processing: "VALID", internal: state),
        build(number: "42", processing: "VALID", internal: "READY_FOR_BETA_TESTING", group_ids: [@group.id])
      ])

      result = guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      assert_equal "READY_FOR_BETA_TESTING", result.internal_state
    end
  end

  def test_finalizer_advances_from_in_beta_testing
    guard, gateway = guard_with([
      build(number: "42", processing: "VALID", internal: "IN_BETA_TESTING", group_ids: [@group.id])
    ])

    result = guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)

    assert_equal "IN_BETA_TESTING", result.internal_state
    assert_equal 0, gateway.associations
  end

  def test_finalizer_rejects_every_terminal_or_unknown_build_state
    %w[FAILED INVALID SOMETHING_NEW].each do |state|
      guard, = guard_with([build(number: "42", processing: state)])
      assert_raises(TestFlightReleaseGuard::FinalizationFailure) do
        guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      end
    end
  end

  def test_finalizer_rejects_every_terminal_or_unknown_internal_state
    %w[MISSING_EXPORT_COMPLIANCE PROCESSING_EXCEPTION EXPIRED SOMETHING_NEW].each do |state|
      guard, = guard_with([build(number: "42", processing: "VALID", internal: state)])
      assert_raises(TestFlightReleaseGuard::FinalizationFailure) do
        guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      end
    end
  end

  def test_finalizer_rejects_expiration_and_encryption_invariants_without_resolving_compliance
    invalid_builds = [
      build(number: "42", expired: true),
      build(number: "42", expiration_date: @clock.now),
      build(number: "42", encryption: true)
    ]

    invalid_builds.each do |invalid_build|
      guard, gateway = guard_with([invalid_build])
      assert_raises(TestFlightReleaseGuard::FinalizationFailure) do
        guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      end
      assert_equal 0, gateway.associations
    end
  end

  def test_finalizer_revalidates_the_post_refetch_snapshot_before_success
    releasable = build(number: "42", group_ids: [@group.id])
    degraded_snapshots = [
      build(number: "42", processing: "PROCESSING", group_ids: [@group.id]),
      build(number: "42", internal: nil, group_ids: [@group.id]),
      build(number: "42", internal: "PROCESSING", group_ids: [@group.id]),
      build(number: "42", internal: "IN_EXPORT_COMPLIANCE_REVIEW", group_ids: [@group.id]),
      build(number: "42", processing: "FAILED", group_ids: [@group.id]),
      build(number: "42", internal: "EXPIRED", group_ids: [@group.id]),
      build(number: "42", expired: true, group_ids: [@group.id]),
      build(number: "42", expiration_date: @clock.now, group_ids: [@group.id]),
      build(number: "42", encryption: true, group_ids: [@group.id])
    ]

    degraded_snapshots.each do |degraded|
      guard, = guard_with([releasable, degraded])
      assert_raises(TestFlightReleaseGuard::FinalizationFailure) do
        guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      end
    end
  end

  def test_finalizer_uses_monotonic_timeout_and_never_reuploads
    guard, gateway = guard_with([build(number: "42", processing: "PROCESSING")])
    @clock.wall += 86_400

    assert_raises(TestFlightReleaseGuard::FinalizationTimeout) do
      guard.finalize(@release, timeout_seconds: 10, poll_interval_seconds: 5)
    end
    assert_equal 0, gateway.associations
  end

  def test_finalizer_is_idempotent_and_refetches_after_conflict_or_ambiguous_mutation
    ready_without_group = build(number: "42")
    ready_with_group = build(number: "42", group_ids: [@group.id])

    [
      TestFlightConnectApiGateway::Conflict.new("conflict"),
      TestFlightConnectApiGateway::AmbiguousMutation.new("ambiguous")
    ].each do |remote_error|
      guard, gateway = guard_with([ready_without_group, ready_with_group])
      gateway.fail_association_with(remote_error)
      assert guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
      assert_equal 1, gateway.associations
    end

    guard, gateway = guard_with([ready_with_group])
    assert guard.finalize(@release, timeout_seconds: 30, poll_interval_seconds: 5)
    assert_equal 0, gateway.associations
  end

  def test_logs_only_sanitized_counts_booleans_states_and_build_numbers
    guard, = guard_with([build(number: "41")])
    guard.preflight(@release)

    serialized = @logger.events.inspect
    [@group.name, *@release.tester_emails, @app.id, @group.id].each do |sensitive|
      refute_includes serialized, sensitive
    end
    assert_includes serialized, "41"
    assert_includes serialized, "eligible_tester_count"
  end

  private

  def guard_with(builds)
    gateway = FakeGateway.new(app: @app, group: @group, users: @users, testers: @testers, builds: builds)
    guard = TestFlightReleaseGuard::Guard.new(
      gateway: gateway,
      clock: @clock,
      sleeper: @sleeper,
      logger: @logger
    )
    [guard, gateway]
  end

  def eligible_user(email, roles: ["DEVELOPER"], app_ids: [@app.id])
    TestFlightReleaseGuard::User.new(
      id: "user-#{email}", email: email, roles: roles, app_ids: app_ids, all_apps_access: false
    )
  end

  def eligible_tester(email, invite_type: "EMAIL", group_ids: [@group.id])
    TestFlightReleaseGuard::BetaTester.new(
      id: "tester-#{email}", app_id: @app.id, email: email, invite_type: invite_type, group_ids: group_ids
    )
  end

  def build(number:, processing: "VALID", internal: "READY_FOR_BETA_TESTING", expired: false,
            expiration_date: @clock.now + 86_400, encryption: false, group_ids: [])
    TestFlightReleaseGuard::Build.new(
      id: "build-#{number}", app_id: @app.id, version: @release.version, build_number: number,
      processing_state: processing, internal_state: internal, expired: expired,
      expiration_date: expiration_date, uses_non_exempt_encryption: encryption, group_ids: group_ids
    )
  end
end

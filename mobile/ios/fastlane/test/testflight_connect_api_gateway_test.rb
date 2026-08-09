# frozen_string_literal: true

require "minitest/autorun"
require_relative "../testflight_connect_api_gateway"

class TestFlightConnectApiGatewayTest < Minitest::Test
  class FakeTransport
    attr_reader :requests, :refreshes, :association_requests

    def initialize(pages:, failure: nil)
      @pages = pages
      @failures = Array(failure)
      @requests = []
      @refreshes = 0
      @association_requests = []
    end

    def fetch(resource:, filters:, cursor:, token:)
      requests << { resource: resource, filters: filters, cursor: cursor, token: token }
      raise @failures.shift unless @failures.empty?
      @pages.fetch(cursor)
    end

    def refresh_token
      @refreshes += 1
      "renewed-token"
    end

    def associate_build_to_group(build_id:, group_id:, token:)
      association_requests << [build_id, group_id, token]
      true
    end
  end

  class FakeClock
    attr_accessor :monotonic

    def initialize
      @monotonic = 10.0
    end

    def now
      monotonic
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

  def test_paginates_maps_and_freezes_dtos_without_leaking_transport_models
    pages = {
      nil => TestFlightConnectApiGateway::Page.new(
        items: [{ "id" => "app-1", "attributes" => { "bundleId" => "com.example.app" } }],
        next_cursor: "page-2"
      ),
      "page-2" => TestFlightConnectApiGateway::Page.new(
        items: [{ "id" => "app-2", "attributes" => { "bundleId" => "com.example.app" } }],
        next_cursor: nil
      )
    }
    gateway = gateway_with(FakeTransport.new(pages: pages))

    apps = gateway.apps(bundle_id: "com.example.app")

    assert_equal %w[app-1 app-2], apps.map(&:id)
    assert apps.all?(&:frozen?)
    assert apps.frozen?
  end

  def test_renews_an_expired_token_once_and_retries_the_same_page
    transport = FakeTransport.new(
      pages: { nil => TestFlightConnectApiGateway::Page.new(items: [], next_cursor: nil) },
      failure: TestFlightConnectApiGateway::Unauthorized.new("raw unauthorized response")
    )
    gateway = gateway_with(transport)

    assert_empty gateway.apps(bundle_id: "com.example.app")
    assert_equal 1, transport.refreshes
    assert_equal [nil, nil], transport.requests.map { |request| request[:cursor] }
    assert_equal ["initial-token", "renewed-token"], transport.requests.map { |request| request[:token] }
  end

  def test_maps_remote_errors_to_sanitized_typed_failures
    transport = FakeTransport.new(
      pages: {},
      failure: TestFlightConnectApiGateway::RemoteResponseError.new(
        status: 503,
        body: "email@example.test resource-secret"
      )
    )
    error = assert_raises(TestFlightConnectApiGateway::RemoteFailure) do
      gateway_with(transport, read_retries: 0).apps(bundle_id: "com.example.app")
    end

    assert_equal "App Store Connect request failed with status 503", error.message
    refute_includes error.message, "email@example.test"
    refute_includes error.message, "resource-secret"
  end

  def test_retries_429_and_5xx_reads_with_sanitized_bounded_retry_after
    clock = FakeClock.new
    sleeper = FakeSleeper.new(clock)
    transport = FakeTransport.new(
      pages: { nil => TestFlightConnectApiGateway::Page.new(items: [], next_cursor: nil) },
      failure: [
        TestFlightConnectApiGateway::RemoteResponseError.new(status: 429, retry_after: "999", body: "private"),
        TestFlightConnectApiGateway::RemoteResponseError.new(status: 503, retry_after: "invalid", body: "private")
      ]
    )

    assert_empty gateway_with(transport, clock: clock, sleeper: sleeper).apps(bundle_id: "com.example.app")
    assert_equal [30, 2], sleeper.durations
    assert_equal 3, transport.requests.length
  end

  def test_read_retry_budget_is_monotonic_and_fails_closed_when_exhausted
    clock = FakeClock.new
    sleeper = FakeSleeper.new(clock)
    failures = Array.new(4) do
      TestFlightConnectApiGateway::RemoteResponseError.new(status: 503, body: "private")
    end
    transport = FakeTransport.new(pages: {}, failure: failures)
    gateway = gateway_with(
      transport,
      clock: clock,
      sleeper: sleeper,
      read_retries: 10,
      read_retry_budget_seconds: 1.5
    )

    assert_raises(TestFlightConnectApiGateway::RemoteFailure) do
      gateway.apps(bundle_id: "com.example.app")
    end
    assert_equal [1, 0.5], sleeper.durations
    assert_equal 3, transport.requests.length
  end

  def test_403_404_and_422_reads_are_terminal_without_retry
    [403, 404, 422].each do |status|
      clock = FakeClock.new
      sleeper = FakeSleeper.new(clock)
      transport = FakeTransport.new(
        pages: {},
        failure: TestFlightConnectApiGateway::RemoteResponseError.new(status: status, body: "private")
      )

      assert_raises(TestFlightConnectApiGateway::RemoteFailure) do
        gateway_with(transport, clock: clock, sleeper: sleeper).apps(bundle_id: "com.example.app")
      end
      assert_empty sleeper.durations
      assert_equal 1, transport.requests.length
    end
  end

  def test_association_maps_409_and_ambiguous_transport_outcomes
    conflict_transport = Class.new(FakeTransport) do
      def associate_build_to_group(**)
        raise TestFlightConnectApiGateway::RemoteResponseError.new(status: 409, body: "private")
      end
    end.new(pages: {})
    ambiguous_transport = Class.new(FakeTransport) do
      def associate_build_to_group(**)
        raise TestFlightConnectApiGateway::TransportAmbiguous.new("socket closed")
      end
    end.new(pages: {})

    assert_raises(TestFlightConnectApiGateway::Conflict) do
      gateway_with(conflict_transport).associate_build_to_group(build_id: "build-id", group_id: "group-id")
    end
    assert_raises(TestFlightConnectApiGateway::AmbiguousMutation) do
      gateway_with(ambiguous_transport).associate_build_to_group(build_id: "build-id", group_id: "group-id")
    end
  end

  def test_association_maps_5xx_to_ambiguous_for_caller_refetch
    transport = Class.new(FakeTransport) do
      def associate_build_to_group(**)
        raise TestFlightConnectApiGateway::RemoteResponseError.new(status: 503, body: "private")
      end
    end.new(pages: {})

    assert_raises(TestFlightConnectApiGateway::AmbiguousMutation) do
      gateway_with(transport).associate_build_to_group(build_id: "build-id", group_id: "group-id")
    end
  end

  def test_association_treats_403_404_and_422_as_terminal
    [403, 404, 422].each do |status|
      transport = Class.new(FakeTransport) do
        define_method(:associate_build_to_group) do |**|
          raise TestFlightConnectApiGateway::RemoteResponseError.new(status: status, body: "private")
        end
      end.new(pages: {})

      assert_raises(TestFlightConnectApiGateway::RemoteFailure) do
        gateway_with(transport).associate_build_to_group(build_id: "build-id", group_id: "group-id")
      end
    end
  end

  def test_association_renews_an_expired_token_once_before_mutating
    transport = Class.new(FakeTransport) do
      def associate_build_to_group(**arguments)
        unless @association_retried
          @association_retried = true
          raise TestFlightConnectApiGateway::Unauthorized, "expired"
        end

        super
      end
    end.new(pages: {})
    gateway = gateway_with(transport)

    assert gateway.associate_build_to_group(build_id: "build-id", group_id: "group-id")
    assert_equal 1, transport.refreshes
    assert_equal "renewed-token", transport.association_requests.first.last
  end

  private

  def gateway_with(transport, **options)
    TestFlightConnectApiGateway::Gateway.new(token: "initial-token", transport: transport, **options)
  end
end

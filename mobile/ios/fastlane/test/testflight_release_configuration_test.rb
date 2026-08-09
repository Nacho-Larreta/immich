# frozen_string_literal: true

require "minitest/autorun"
require_relative "../testflight_release_configuration"

class TestFlightReleaseConfigurationTest < Minitest::Test
  TEAM_AUTH = {
    "ASC_KEY_TYPE" => "team",
    "ASC_KEY_ID" => "key-id",
    "ASC_KEY_PATH" => "/secure/key.p8",
    "ASC_ISSUER_ID" => "123e4567-e89b-12d3-a456-426614174000"
  }.freeze

  INDIVIDUAL_AUTH = TEAM_AUTH.merge(
    "ASC_KEY_TYPE" => "individual",
    "ASC_ISSUER_ID" => "none"
  ).freeze

  RELEASE_ENV = {
    "ASC_TEAM_ID" => "asc-team",
    "DEVELOPER_PORTAL_TEAM_ID" => "developer-team",
    "TESTFLIGHT_INTERNAL_GROUP" => "Private Family",
    "TESTFLIGHT_TESTER_EMAIL_1" => "one@example.test",
    "TESTFLIGHT_TESTER_EMAIL_2" => "two@example.test",
    "EXPECTED_VERSION" => "1.142.0",
    "EXPECTED_PREVIOUS_BUILD_NUMBER" => "41",
    "EXPECTED_BUILD_NUMBER" => "42",
    "IPA_PATH" => "/artifacts/immich.ipa"
  }.freeze

  def test_accepts_team_and_individual_authentication_without_deriving_the_key_path
    team = TestFlightReleaseConfiguration::ApiKey.from_env(TEAM_AUTH)
    individual = TestFlightReleaseConfiguration::ApiKey.from_env(INDIVIDUAL_AUTH)

    assert_equal "/secure/key.p8", team.key_path
    assert_equal "123e4567-e89b-12d3-a456-426614174000", team.issuer_id
    assert_nil individual.issuer_id
    assert_equal "/secure/key.p8", individual.key_path
    refute_includes team.inspect, "key-id"
    refute_includes team.inspect, "/secure/key.p8"
    refute_includes team.inspect, team.issuer_id
  end

  def test_rejects_missing_authentication_values_and_invalid_key_type_rules
    TEAM_AUTH.each_key do |name|
      error = assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
        TestFlightReleaseConfiguration::ApiKey.from_env(TEAM_AUTH.merge(name => " "))
      end
      assert_includes error.message, name
    end

    assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
      TestFlightReleaseConfiguration::ApiKey.from_env(TEAM_AUTH.merge("ASC_KEY_TYPE" => "shared"))
    end
    assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
      TestFlightReleaseConfiguration::ApiKey.from_env(TEAM_AUTH.merge("ASC_ISSUER_ID" => "not-a-uuid"))
    end
    assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
      TestFlightReleaseConfiguration::ApiKey.from_env(INDIVIDUAL_AUTH.merge("ASC_ISSUER_ID" => "123e4567-e89b-12d3-a456-426614174000"))
    end
  end

  def test_requires_separate_team_ids_release_coordinates_ipa_and_two_distinct_emails
    release = TestFlightReleaseConfiguration::Release.from_env(
      RELEASE_ENV,
      bundle_id: "com.nacholarreta.nachofotos"
    )

    assert_equal "asc-team", release.asc_team_id
    assert_equal "developer-team", release.developer_portal_team_id
    assert_equal ["one@example.test", "two@example.test"], release.tester_emails
    assert release.frozen?
    refute_includes release.inspect, "one@example.test"
    refute_includes release.inspect, "Private Family"
    refute_includes release.inspect, "/artifacts/immich.ipa"

    RELEASE_ENV.each_key do |name|
      error = assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
        TestFlightReleaseConfiguration::Release.from_env(
          RELEASE_ENV.merge(name => ""),
          bundle_id: "com.nacholarreta.nachofotos"
        )
      end
      assert_includes error.message, name
    end

    assert_raises(TestFlightReleaseConfiguration::InvalidConfiguration) do
      TestFlightReleaseConfiguration::Release.from_env(
        RELEASE_ENV.merge("TESTFLIGHT_TESTER_EMAIL_2" => "one@example.test"),
        bundle_id: "com.nacholarreta.nachofotos"
      )
    end
  end
end

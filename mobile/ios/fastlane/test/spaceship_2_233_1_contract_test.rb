# frozen_string_literal: true

require "minitest/autorun"
require "fastlane"
require "spaceship"

class Spaceship22331ContractTest < Minitest::Test
  def test_pinned_fastlane_version_exposes_the_adapter_seam
    assert_equal "2.233.1", Fastlane::VERSION
    assert_respond_to Spaceship::ConnectAPI::App, :all
    assert_respond_to Spaceship::ConnectAPI::App, :get
    assert_respond_to Spaceship::ConnectAPI::User, :all
    assert_respond_to Spaceship::ConnectAPI::BetaTester, :all
    assert_respond_to Spaceship::ConnectAPI::Build, :all
    assert_respond_to Spaceship::ConnectAPI, :add_beta_groups_to_build
  end

  def test_models_expose_every_eagerly_snapshotted_attribute
    assert_includes Spaceship::ConnectAPI::User.instance_methods, :visible_apps
    assert_includes Spaceship::ConnectAPI::BetaTester.instance_methods, :invite_type
    assert_includes Spaceship::ConnectAPI::BetaTester.instance_methods, :beta_groups
    assert_includes Spaceship::ConnectAPI::Build.instance_methods, :build_beta_detail
    assert_includes Spaceship::ConnectAPI::Build.instance_methods, :pre_release_version
    assert_includes Spaceship::ConnectAPI::Build.instance_methods, :uses_non_exempt_encryption
  end
end

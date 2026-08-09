# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require_relative "../production_build_plan"

class ProductionBuildPlanTest < Minitest::Test
  BUNDLE_ID = "com.nacholarreta.nachofotos"

  def setup
    @temporary_root = Dir.mktmpdir
    File.chmod(0o700, @temporary_root)
    @profiles = {
      "RUNNER_PROFILE_PATH" => private_file("runner.mobileprovision"),
      "SHARE_EXTENSION_PROFILE_PATH" => private_file("share.mobileprovision"),
      "WIDGET_EXTENSION_PROFILE_PATH" => private_file("widget.mobileprovision")
    }
    @env = {
      "EXPECTED_VERSION" => "1.142.0",
      "EXPECTED_PREVIOUS_BUILD_NUMBER" => "41",
      "EXPECTED_BUILD_NUMBER" => "42",
      "IPA_PATH" => File.join(@temporary_root, "NachoFotos.ipa"),
      "ARCHIVE_PATH" => File.join(@temporary_root, "NachoFotos.xcarchive"),
      "DEVELOPER_PORTAL_TEAM_ID" => ProductionBuildPlan::Plan::DEVELOPER_PORTAL_TEAM_ID,
      "KEYCHAIN_NAME" => "nachofotos-build.keychain-db",
      "SIGNING_CERTIFICATE_SHA256" => "a" * 64
    }.merge(@profiles)
  end

  def teardown
    FileUtils.remove_entry(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_parses_the_exact_immutable_production_build_plan
    plan = build_plan(@env.merge("UNRELATED_XCODE_SETTING" => "ignored"))

    assert_equal "1.142.0", plan.version
    assert_equal "41", plan.previous_build_number
    assert_equal "42", plan.build_number
    assert_equal File.join(@temporary_root, "NachoFotos.ipa"), plan.ipa_path
    assert_equal File.join(@temporary_root, "NachoFotos.xcarchive"), plan.archive_path
    assert_equal ProductionBuildPlan::Plan::DEVELOPER_PORTAL_TEAM_ID, plan.developer_portal_team_id
    assert_equal "nachofotos-build.keychain-db", plan.keychain_name
    assert_equal "a" * 64, plan.signing_certificate_sha256
    assert_equal(
      [BUNDLE_ID, "#{BUNDLE_ID}.ShareExtension", "#{BUNDLE_ID}.WidgetExtension"],
      plan.profiles.map(&:bundle_id)
    )
    assert_equal(
      {
        BUNDLE_ID => @profiles.fetch("RUNNER_PROFILE_PATH"),
        "#{BUNDLE_ID}.ShareExtension" => @profiles.fetch("SHARE_EXTENSION_PROFILE_PATH"),
        "#{BUNDLE_ID}.WidgetExtension" => @profiles.fetch("WIDGET_EXTENSION_PROFILE_PATH")
      },
      plan.provisioning_profiles
    )
    assert plan.frozen?
    assert plan.profiles.frozen?
    assert plan.profiles.all?(&:frozen?)
    assert plan.provisioning_profiles.frozen?
    refute_respond_to plan, :unrelated_xcode_setting
  end

  def test_signing_inputs_remain_available_for_validating_an_existing_upload_artifact
    File.write(@env.fetch("IPA_PATH"), "built ipa")
    Dir.mkdir(@env.fetch("ARCHIVE_PATH"), 0o700)

    inputs = ProductionBuildPlan::Plan.signing_inputs_from_env(@env, bundle_id: BUNDLE_ID)

    assert_equal @env.fetch("SIGNING_CERTIFICATE_SHA256"), inputs.signing_certificate_sha256
    assert_equal @profiles.values, inputs.profiles.map(&:path)
    assert inputs.frozen?
  end

  def test_requires_only_explicit_strict_allowlisted_values
    ProductionBuildPlan::Plan::REQUIRED_ENV_NAMES.each do |name|
      [nil, "", " value "].each do |invalid|
        error = assert_raises(ProductionBuildPlan::InvalidPlan) do
          build_plan(@env.merge(name => invalid))
        end

        assert_includes error.message, name
        refute_includes error.message, invalid.to_s unless invalid.to_s.empty?
      end
    end
  end

  def test_requires_a_canonical_three_part_semantic_version
    ["1.142", "1.142.0.1", "v1.142.0", "01.142.0", "1.0142.0", "1.142.00", "1.142.0-beta"].each do |version|
      error = assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("EXPECTED_VERSION" => version))
      end

      assert_includes error.message, "EXPECTED_VERSION"
      refute_includes error.message, version
    end
  end

  def test_requires_consecutive_canonical_positive_build_numbers
    ["0", "-1", "+41", "041", "4 1", "forty-one"].each do |number|
      assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("EXPECTED_PREVIOUS_BUILD_NUMBER" => number))
      end
    end

    ["41", "43"].each do |number|
      assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("EXPECTED_BUILD_NUMBER" => number))
      end
    end
  end

  def test_requires_absent_absolute_output_destinations_in_a_private_owned_real_parent
    %w[IPA_PATH ARCHIVE_PATH].each do |name|
      extension = name == "IPA_PATH" ? ".ipa" : ".xcarchive"
      assert_invalid_path(name, "relative/output#{extension}")

      existing = File.join(@temporary_root, "existing#{extension}")
      File.write(existing, "do-not-overwrite")
      assert_invalid_path(name, existing)

      target = File.join(@temporary_root, "target#{extension}")
      symlink = File.join(@temporary_root, "link#{extension}")
      File.symlink(target, symlink)
      assert_invalid_path(name, symlink)
    end

    insecure_parent = Dir.mktmpdir
    File.chmod(0o755, insecure_parent)
    assert_invalid_path("IPA_PATH", File.join(insecure_parent, "output.ipa"))

    Process.stub(:euid, Process.euid + 1) do
      assert_invalid_path("IPA_PATH", File.join(@temporary_root, "owned-by-someone-else.ipa"))
    end
  ensure
    FileUtils.remove_entry(insecure_parent) if insecure_parent && File.exist?(insecure_parent)
  end

  def test_requires_output_extensions_and_distinct_destinations
    assert_invalid_path("IPA_PATH", File.join(@temporary_root, "output.zip"))
    assert_invalid_path("ARCHIVE_PATH", File.join(@temporary_root, "output.archive"))
  end

  def test_requires_three_existing_private_owned_regular_non_symlink_profiles
    @profiles.each_key do |name|
      missing = File.join(@temporary_root, "missing.mobileprovision")
      assert_invalid_path(name, missing)

      directory = File.join(@temporary_root, "directory.mobileprovision")
      Dir.mkdir(directory, 0o700) unless File.exist?(directory)
      assert_invalid_path(name, directory)

      public_file = private_file("public-#{name}.mobileprovision")
      File.chmod(0o644, public_file)
      assert_invalid_path(name, public_file)

      symlink = File.join(@temporary_root, "link-#{name}.mobileprovision")
      File.symlink(@profiles.fetch(name), symlink)
      assert_invalid_path(name, symlink)
    end

    assert_raises(ProductionBuildPlan::InvalidPlan) do
      build_plan(
        @env.merge(
          "SHARE_EXTENSION_PROFILE_PATH" => @profiles.fetch("RUNNER_PROFILE_PATH")
        )
      )
    end
  end

  def test_requires_the_exact_developer_team_strict_keychain_name_and_lowercase_fingerprint
    ["OTHERTEAM1", "32ns8mr6ua"].each do |team_id|
      assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("DEVELOPER_PORTAL_TEAM_ID" => team_id))
      end
    end

    [" keychain", "keychain ", "key\nchain"].each do |keychain_name|
      assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("KEYCHAIN_NAME" => keychain_name))
      end
    end

    ["A" * 64, "a" * 63, "g" * 64].each do |fingerprint|
      assert_raises(ProductionBuildPlan::InvalidPlan) do
        build_plan(@env.merge("SIGNING_CERTIFICATE_SHA256" => fingerprint))
      end
    end
  end

  def test_errors_and_inspection_never_echo_environment_values
    secret = "never-echo-this-value"
    error = assert_raises(ProductionBuildPlan::InvalidPlan) do
      build_plan(@env.merge("KEYCHAIN_NAME" => "#{secret}\n"))
    end
    plan = build_plan

    refute_includes error.message, secret
    @env.each_value { |value| refute_includes plan.inspect, value }
  end

  private

  def build_plan(env = @env)
    ProductionBuildPlan::Plan.from_env(env, bundle_id: BUNDLE_ID)
  end

  def private_file(name)
    path = File.join(@temporary_root, name)
    File.write(path, "profile")
    File.chmod(0o600, path)
    path
  end

  def assert_invalid_path(name, path)
    error = assert_raises(ProductionBuildPlan::InvalidPlan) do
      build_plan(@env.merge(name => path))
    end

    assert_includes error.message, name
    refute_includes error.message, path
  end
end

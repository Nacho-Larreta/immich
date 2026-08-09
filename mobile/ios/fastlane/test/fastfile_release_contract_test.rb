# frozen_string_literal: true

require "minitest/autorun"
require "sigh"

class FastfileReleaseContractTest < Minitest::Test
  FASTFILE = File.read(File.expand_path("../Fastfile", __dir__))
  RUNTIME = File.read(File.expand_path("../exact_release_runtime.rb", __dir__))

  def test_exposes_only_the_protected_production_release_phases
    %w[
      nacho_testflight_preflight_prod
      nacho_prepare_signing_prod
      nacho_build_exact_prod
      nacho_upload_exact_prod
      nacho_finalize_testflight_prod
    ].each do |lane|
      assert_match(/lane :#{lane}\b/, FASTFILE)
    end
  end

  def test_exact_build_uses_one_local_release_build_with_explicit_destinations_and_versions
    lane = lane_source("nacho_build_exact_prod")

    assert_equal 1, lane.scan(/\bbuild_app\s*\(/).length
    assert_includes lane, "ProductionBuildPlan::Plan.from_env(ENV, bundle_id: BASE_BUNDLE_ID)"
    assert_includes lane, 'workspace: "Runner.xcworkspace"'
    assert_includes lane, 'scheme: "Runner"'
    assert_includes lane, 'configuration: "Release"'
    assert_includes lane, 'export_method: "app-store-connect"'
    assert_includes lane, "archive_path: plan.archive_path"
    assert_includes lane, "output_directory: File.dirname(plan.ipa_path)"
    assert_includes lane, "output_name: File.basename(plan.ipa_path)"
    assert_includes RUNTIME, '"MARKETING_VERSION=#{plan.version}"'
    assert_includes RUNTIME, '"CURRENT_PROJECT_VERSION=#{plan.build_number}"'
    assert_includes lane, "provisioningProfiles: profile_uuids"
    assert_includes lane, 'signingStyle: "manual"'
    assert_includes lane, "teamID: plan.developer_portal_team_id"
  end

  def test_exact_build_verifies_local_signing_profiles_artifact_and_tracked_configuration_in_order
    lane = lane_source("nacho_build_exact_prod")

    assert_ordered(
      lane,
      "tracked_configuration_before = tracked_build_configuration_digest",
      "verify_installed_signing_identity!(plan)",
      "profile_uuids = verified_profile_uuids!(plan)",
      "build_app(",
      "secure_private_ipa!(plan.ipa_path)",
      "validate_exact_ipa!(plan.ipa_path, contract)"
    )
    assert_includes lane, "verify_tracked_build_configuration_unchanged!(tracked_configuration_before)"
    assert_match(/ensure.*verify_tracked_build_configuration_unchanged!/m, lane)
  end

  def test_exact_build_has_no_remote_signing_version_mutation_or_upload_actions
    lane = lane_source("nacho_build_exact_prod")

    %w[
      app_store_connect_api_key
      api_key_configuration
      cert
      get_api_key
      sigh
      upload_to_testflight
      increment_version_number
      increment_build_number
      latest_testflight_build_number
      update_code_signing_settings
    ].each do |forbidden_action|
      refute_match(/\b#{forbidden_action}\s*\(/, lane)
    end
  end

  def test_build_and_upload_share_the_strict_artifact_contract_and_validated_snapshot
    build_lane = lane_source("nacho_build_exact_prod")
    upload_lane = lane_source("nacho_upload_exact_prod")

    assert_includes build_lane, "contract = production_artifact_contract("
    assert_includes build_lane, "provisioning_profile_uuids: profile_uuids"
    assert_includes build_lane, "validate_exact_ipa!(plan.ipa_path, contract)"
    assert_includes upload_lane, "contract = production_artifact_contract("
    assert_includes upload_lane, "ProductionBuildPlan::Plan.signing_inputs_from_env"
    assert_includes upload_lane, "provisioning_profile_uuids: profile_uuids"
    assert_includes upload_lane, "artifact = snapshot_exact_ipa!(release, contract)"
    assert_includes upload_lane, "artifact.verify_unchanged!"
    assert_includes upload_lane, "ipa: artifact.path"
    refute_includes upload_lane, "ipa: release.ipa_path"
    assert_ordered(
      upload_lane,
      "run_production_preflight(release, configuration)",
      "artifact = snapshot_exact_ipa!(release, contract)",
      "artifact.verify_unchanged!",
      "upload_to_testflight("
    )

    snapshot_helper = method_source("snapshot_exact_ipa!")
    assert_includes snapshot_helper, "exact_release_runtime.snapshot_exact_ipa!(release.ipa_path, contract)"
    assert_includes RUNTIME, "contract: contract"
    assert_includes RUNTIME, "archive_metadata: inspection"
    assert_includes RUNTIME, "codesign_verifier: inspection"
    refute_includes snapshot_helper, "metadata_reader:"
  end

  def test_artifact_adapters_use_argv_commands_without_shell_interpolation
    assert_includes RUNTIME, 'Open3.capture3(*argv)'
    assert_includes RUNTIME, '["/usr/bin/ditto", "-x", "-k", ipa_path, @directory]'
    assert_includes RUNTIME, '["/usr/bin/codesign", "--verify", "--deep", "--strict", bundle_path]'
    refute_match(/\b(sh|system|exec)\s*\(/, method_source("validate_exact_ipa!"))
  end

  def test_exact_upload_waits_and_never_distributes_externally_or_selects_signing
    lane = lane_source("nacho_upload_exact_prod")

    assert_includes lane, "skip_waiting_for_build_processing: false"
    assert_includes lane, "wait_processing_timeout_duration: 3600"
    assert_includes lane, "skip_submission: true"
    assert_includes lane, "distribute_external: false"
    assert_includes lane, "app_version: release.version"
    assert_includes lane, "build_number: release.build_number"
    assert_includes lane, "team_id: release.asc_team_id"
    assert_includes lane, "dev_portal_team_id: release.developer_portal_team_id"
    assert_includes lane, "artifact.verify_unchanged!"
    assert_includes lane, "ipa: artifact.path"
    assert_includes lane, "artifact.cleanup!"
    refute_includes lane, "ipa: release.ipa_path"
    refute_match(/\bcert\s*\(/, lane)
    refute_match(/\bsigh\s*\(/, lane)
  end

  def test_finalizer_has_no_upload_action
    refute_includes lane_source("nacho_finalize_testflight_prod"), "upload_to_testflight"
  end

  def test_signing_lane_verifies_identity_portal_certificate_and_profiles_before_readiness
    lane = lane_source("nacho_prepare_signing_prod")

    assert_match(/IdentityVerifier\.verify_pkcs12!.*verify_portal_certificate!.*verify_profiles!.*import_certificate/m, lane)
    assert_match(/EncryptedBackup\.secure_created_identity!.*verify_portal_certificate!.*sigh\(.*verify_profiles!.*state\.profile_ready!/m, lane)
    assert_match(/with_private_file_umask do.*cert\(.*force: true/m, lane)
    assert_includes lane, "EncryptedBackup.remove_plaintext_private_keys!"
    refute_match(/sigh\(.*force:\s*true/m, lane)
    assert_match(/plan\.profiles\.each do \|profile\|.*sigh\(.*force:\s*false/m, lane)
    refute_match(/\b(delete|revoke)\w*!?\s*\(/, lane)
  end

  def test_signing_import_targets_an_explicit_configurable_keychain
    lane = lane_source("nacho_prepare_signing_prod")

    assert_includes lane, 'keychain_name: ENV.fetch("KEYCHAIN_NAME", "login.keychain")'
  end

  def test_explicit_sigh_force_false_overrides_true_environment_default
    previous = ENV["SIGH_FORCE"]
    ENV["SIGH_FORCE"] = "true"

    configuration = FastlaneCore::Configuration.create(Sigh::Options.available_options, force: false)

    assert_equal false, configuration[:force]
  ensure
    ENV["SIGH_FORCE"] = previous
  end

  def test_legacy_production_lanes_fail_explicitly_or_delegate_to_the_protected_workflow
    %w[gha_release_prod nacho_latest_prod_build nacho_upload_current_prod release_manual].each do |lane|
      source = lane_source(lane)
      assert_match(/protected|nacho_upload_exact_prod|user_error!/, source)
    end
  end

  private

  def assert_ordered(source, *fragments)
    positions = fragments.map do |fragment|
      source.index(fragment) || flunk("Missing ordered fragment: #{fragment}")
    end
    assert_equal positions.sort, positions
  end

  def lane_source(name)
    start = FASTFILE.index(/lane :#{name}\b/)
    raise "Missing lane #{name}" unless start

    following_lane = FASTFILE.index(/^\s*lane :/, start + 1)
    FASTFILE[start...(following_lane || FASTFILE.length)]
  end

  def method_source(name)
    match = FASTFILE.match(/^\s*def #{Regexp.escape(name)}(?:\(|\s|$)/)
    start = match&.begin(0)
    raise "Missing method #{name}" unless start

    following_method = FASTFILE.index(/^\s*def /, match.end(0))
    FASTFILE[start...(following_method || FASTFILE.length)]
  end
end

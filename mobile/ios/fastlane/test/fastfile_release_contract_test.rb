# frozen_string_literal: true

require "minitest/autorun"
require "sigh"

class FastfileReleaseContractTest < Minitest::Test
  FASTFILE = File.read(File.expand_path("../Fastfile", __dir__))

  def test_exposes_only_the_protected_production_release_phases
    %w[
      nacho_testflight_preflight_prod
      nacho_prepare_signing_prod
      nacho_upload_exact_prod
      nacho_finalize_testflight_prod
    ].each do |lane|
      assert_match(/lane :#{lane}\b/, FASTFILE)
    end
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

  def lane_source(name)
    start = FASTFILE.index(/lane :#{name}\b/)
    raise "Missing lane #{name}" unless start

    following_lane = FASTFILE.index(/^\s*lane :/, start + 1)
    FASTFILE[start...(following_lane || FASTFILE.length)]
  end
end

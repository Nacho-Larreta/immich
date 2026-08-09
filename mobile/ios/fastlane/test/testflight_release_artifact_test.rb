# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../testflight_release_artifact"

class TestFlightReleaseArtifactTest < Minitest::Test
  BUNDLE_ID = "com.nacholarreta.nachofotos"
  TEAM_ID = "32NS8MR6UA"
  CERTIFICATE_SHA256 = "a" * 64
  PROFILE_UUIDS = {
    BUNDLE_ID => "11111111-1111-4111-8111-111111111111",
    "#{BUNDLE_ID}.ShareExtension" => "22222222-2222-4222-8222-222222222222",
    "#{BUNDLE_ID}.WidgetExtension" => "33333333-3333-4333-8333-333333333333"
  }.freeze
  MAIN_BUNDLE_PATH = "Payload/Nacho Fotos.app"
  SHARE_BUNDLE_PATH = "#{MAIN_BUNDLE_PATH}/PlugIns/ShareExtension.appex"
  WIDGET_BUNDLE_PATH = "#{MAIN_BUNDLE_PATH}/PlugIns/WidgetExtension.appex"

  METADATA = {
    "CFBundleIdentifier" => "com.example.private",
    "CFBundleShortVersionString" => "2.7.5",
    "CFBundleVersion" => "3047",
    "ITSAppUsesNonExemptEncryption" => false
  }.freeze

  class FakeArchiveMetadata
    attr_accessor :bundle_paths, :info_by_path, :entitlements_by_path, :certificate_by_path,
                  :profile_uuid_by_path

    def initialize(contract)
      @bundle_paths = contract.bundles.map(&:archive_path)
      @info_by_path = contract.bundles.each_with_object({}) do |bundle, result|
        result[bundle.archive_path] = {
          "CFBundleIdentifier" => bundle.bundle_id,
          "CFBundleShortVersionString" => contract.version,
          "CFBundleVersion" => contract.build_number,
          "ITSAppUsesNonExemptEncryption" => false
        }
      end
      @entitlements_by_path = contract.bundles.each_with_object({}) do |bundle, result|
        result[bundle.archive_path] = {
          "com.apple.developer.team-identifier" => contract.team_id,
          "application-identifier" => bundle.application_identifier
        }
      end
      @certificate_by_path = contract.bundles.each_with_object({}) do |bundle, result|
        result[bundle.archive_path] = contract.signing_certificate_sha256
      end
      @profile_uuid_by_path = contract.bundles.each_with_object({}) do |bundle, result|
        result[bundle.archive_path] = bundle.provisioning_profile_uuid
      end
    end

    def bundle_paths(_ipa_path)
      @bundle_paths
    end

    def info_plist(_ipa_path, bundle_path)
      @info_by_path.fetch(bundle_path)
    end

    def entitlements(_ipa_path, bundle_path)
      @entitlements_by_path.fetch(bundle_path)
    end

    def signing_certificate_sha256(_ipa_path, bundle_path)
      @certificate_by_path.fetch(bundle_path)
    end

    def provisioning_profile_uuid(_ipa_path, bundle_path)
      @profile_uuid_by_path.fetch(bundle_path)
    end
  end

  class FakeCodeSignVerifier
    attr_accessor :result
    attr_reader :verified_bundle_paths

    def initialize(result: true)
      @result = result
      @verified_bundle_paths = []
    end

    def verify!(_ipa_path, bundle_path)
      verified_bundle_paths << bundle_path
      result
    end
  end

  def test_contract_defines_the_exact_app_and_extension_release_identity
    contract = strict_contract

    assert_equal 0o600, contract.output_file_mode
    assert_equal [
      [MAIN_BUNDLE_PATH, BUNDLE_ID, "#{TEAM_ID}.#{BUNDLE_ID}", PROFILE_UUIDS.fetch(BUNDLE_ID)],
      [SHARE_BUNDLE_PATH, "#{BUNDLE_ID}.ShareExtension", "#{TEAM_ID}.#{BUNDLE_ID}.ShareExtension",
       PROFILE_UUIDS.fetch("#{BUNDLE_ID}.ShareExtension")],
      [WIDGET_BUNDLE_PATH, "#{BUNDLE_ID}.WidgetExtension", "#{TEAM_ID}.#{BUNDLE_ID}.WidgetExtension",
       PROFILE_UUIDS.fetch("#{BUNDLE_ID}.WidgetExtension")]
    ], contract.bundles.map { |bundle|
      [bundle.archive_path, bundle.bundle_id, bundle.application_identifier, bundle.provisioning_profile_uuid]
    }
    assert contract.frozen?
    assert contract.bundles.frozen?
    assert contract.bundles.all?(&:frozen?)
  end

  def test_strict_contract_validates_the_snapshot_and_every_code_signature
    with_source_ipa do |source, temporary_root|
      contract = strict_contract
      metadata = FakeArchiveMetadata.new(contract)
      codesign = FakeCodeSignVerifier.new

      snapshot = TestFlightReleaseArtifact::Snapshot.create(
        source_path: source,
        contract: contract,
        archive_metadata: metadata,
        codesign_verifier: codesign,
        temporary_root: temporary_root
      )

      assert_equal contract.bundles.map(&:archive_path), codesign.verified_bundle_paths
      assert snapshot.verify_unchanged!
      snapshot.cleanup!
    end
  end

  def test_strict_contract_rejects_missing_extra_duplicate_or_misplaced_bundles
    invalid_paths = [
      [MAIN_BUNDLE_PATH, SHARE_BUNDLE_PATH],
      [MAIN_BUNDLE_PATH, SHARE_BUNDLE_PATH, WIDGET_BUNDLE_PATH, "Payload/Other.app"],
      [MAIN_BUNDLE_PATH, SHARE_BUNDLE_PATH, SHARE_BUNDLE_PATH],
      [MAIN_BUNDLE_PATH, SHARE_BUNDLE_PATH, "Payload/Nacho Fotos.app/WidgetExtension.appex"]
    ]

    invalid_paths.each do |paths|
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.bundle_paths = paths
      end
    end
  end

  def test_strict_contract_rejects_identity_or_release_metadata_drift_for_every_bundle
    strict_contract.bundles.each do |bundle|
      [
        ["CFBundleIdentifier", "com.example.wrong"],
        ["CFBundleShortVersionString", "1.141.0"],
        ["CFBundleVersion", "41"]
      ].each do |key, value|
        assert_strict_snapshot_rejected do |metadata, _codesign|
          metadata.info_by_path[bundle.archive_path][key] = value
        end
      end
    end
  end

  def test_strict_contract_rejects_team_application_identifier_and_certificate_drift_for_every_bundle
    strict_contract.bundles.each do |bundle|
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.entitlements_by_path[bundle.archive_path]["com.apple.developer.team-identifier"] = "OTHERTEAM"
      end
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.entitlements_by_path[bundle.archive_path]["application-identifier"] = "#{TEAM_ID}.wrong"
      end
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.certificate_by_path[bundle.archive_path] = "b" * 64
      end
    end
  end

  def test_strict_contract_rejects_wrong_embedded_provisioning_profile_uuid_for_every_bundle
    strict_contract.bundles.each do |bundle|
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.profile_uuid_by_path[bundle.archive_path] = "ffffffff-ffff-4fff-8fff-ffffffffffff"
      end
    end
  end

  def test_strict_contract_requires_successful_codesign_verify_semantics
    assert_strict_snapshot_rejected do |_metadata, codesign|
      codesign.result = false
    end
  end

  def test_validator_can_enforce_the_same_contract_on_a_builder_output
    Dir.mktmpdir do |directory|
      output = File.join(directory, "release.ipa")
      File.binwrite(output, "builder output")
      File.chmod(0o600, output)
      contract = strict_contract
      validator = TestFlightReleaseArtifact::Validator.new(
        contract: contract,
        archive_metadata: FakeArchiveMetadata.new(contract),
        codesign_verifier: FakeCodeSignVerifier.new
      )

      assert validator.validate!(output)

      File.chmod(0o644, output)
      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) { validator.validate!(output) }
    end
  end

  def test_strict_contract_requires_false_encryption_declaration_only_on_main_app
    [true, nil].each do |value|
      assert_strict_snapshot_rejected do |metadata, _codesign|
        metadata.info_by_path[MAIN_BUNDLE_PATH]["ITSAppUsesNonExemptEncryption"] = value
      end
    end

    with_source_ipa do |source, temporary_root|
      contract = strict_contract
      metadata = FakeArchiveMetadata.new(contract)
      metadata.info_by_path[SHARE_BUNDLE_PATH].delete("ITSAppUsesNonExemptEncryption")
      metadata.info_by_path[WIDGET_BUNDLE_PATH].delete("ITSAppUsesNonExemptEncryption")
      snapshot = TestFlightReleaseArtifact::Snapshot.create(
        source_path: source,
        contract: contract,
        archive_metadata: metadata,
        codesign_verifier: FakeCodeSignVerifier.new,
        temporary_root: temporary_root
      )

      assert snapshot.verify_unchanged!
      snapshot.cleanup!
    end
  end

  def test_strict_contract_rejects_a_snapshot_that_is_not_mode_0600
    with_source_ipa do |source, temporary_root|
      contract = strict_contract
      metadata = FakeArchiveMetadata.new(contract)
      metadata.define_singleton_method(:bundle_paths) do |ipa_path|
        File.chmod(0o640, ipa_path)
        @bundle_paths
      end

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        TestFlightReleaseArtifact::Snapshot.create(
          source_path: source,
          contract: contract,
          archive_metadata: metadata,
          codesign_verifier: FakeCodeSignVerifier.new,
          temporary_root: temporary_root
        )
      end
      assert_empty Dir.children(temporary_root)
    end
  end

  def test_snapshot_is_independent_from_later_source_mutation
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)
      original_snapshot = File.binread(snapshot.path)

      File.binwrite(source, "changed after snapshot")

      assert_equal original_snapshot, File.binread(snapshot.path)
      assert snapshot.verify_unchanged!
      snapshot.cleanup!
    end
  end

  def test_copies_and_validates_a_private_snapshot_then_cleans_it
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)

      refute_equal source, snapshot.path
      assert_equal File.binread(source), File.binread(snapshot.path)
      assert_equal 0o600, File.stat(snapshot.path).mode & 0o777
      assert snapshot.verify_unchanged!

      snapshot.cleanup!
      refute File.exist?(snapshot.path)
    end
  end

  def test_snapshot_sets_mode_0600_even_under_a_more_restrictive_process_umask
    with_source_ipa do |source, temporary_root|
      previous_umask = File.umask(0o777)
      snapshot = create_snapshot(source, temporary_root: temporary_root)

      assert_equal 0o600, File.stat(snapshot.path).mode & 0o777
      snapshot.cleanup!
    ensure
      File.umask(previous_umask) if previous_umask
    end
  end

  def test_rejects_bundle_id_and_encryption_mismatch_and_cleans_partial_snapshot
    invalid_metadata = [
      METADATA.merge("CFBundleIdentifier" => "com.example.other"),
      METADATA.merge("ITSAppUsesNonExemptEncryption" => true),
      METADATA.merge("ITSAppUsesNonExemptEncryption" => nil)
    ]

    invalid_metadata.each do |metadata|
      with_source_ipa do |source, temporary_root|
        assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
          create_snapshot(source, temporary_root: temporary_root, metadata: metadata)
        end
        assert_empty Dir.children(temporary_root)
      end
    end
  end

  def test_detects_snapshot_content_replacement
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)
      File.binwrite(snapshot.path, "replacement")

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) { snapshot.verify_unchanged! }
      snapshot.cleanup!
      refute File.exist?(snapshot.path)
    end
  end

  def test_cleanup_preserves_racer_that_wins_just_before_move
    with_source_ipa do |source, temporary_root|
      snapshot = create_snapshot(source, temporary_root: temporary_root)
      racer_content = "racer-must-survive"

      snapshot.cleanup!(
        before_remove: lambda do
          racer = File.join(File.dirname(snapshot.path), "racer")
          File.binwrite(racer, racer_content)
          File.rename(racer, snapshot.path)
        end
      )

      assert_equal racer_content, File.binread(snapshot.path)
      assert_empty Dir.children(File.dirname(snapshot.path)).grep(/immich-quarantine/)
    end
  end

  def test_partial_cleanup_preserves_racer_that_wins_just_before_move
    with_source_ipa do |source, temporary_root|
      racer_content = "racer-must-survive"
      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        TestFlightReleaseArtifact::Snapshot.create(
          source_path: source,
          bundle_id: METADATA.fetch("CFBundleIdentifier"),
          version: METADATA.fetch("CFBundleShortVersionString"),
          build_number: METADATA.fetch("CFBundleVersion"),
          metadata_reader: ->(_path, key) { METADATA.merge("CFBundleIdentifier" => "wrong")[key] },
          temporary_root: temporary_root,
          before_partial_cleanup: lambda do
            snapshot_directory = File.join(temporary_root, Dir.children(temporary_root).fetch(0))
            path = File.join(snapshot_directory, "release.ipa")
            racer = File.join(snapshot_directory, "racer")
            File.binwrite(racer, racer_content)
            File.rename(racer, path)
          end
        )
      end

      snapshot_directory = File.join(temporary_root, Dir.children(temporary_root).fetch(0))
      assert_equal racer_content, File.binread(File.join(snapshot_directory, "release.ipa"))
      assert_empty Dir.children(snapshot_directory).grep(/immich-quarantine/)
    end
  end

  def test_rejects_source_symlink
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.ipa")
      symlink = File.join(directory, "symlink.ipa")
      File.binwrite(source, "ipa")
      File.symlink(source, symlink)

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        create_snapshot(symlink, temporary_root: directory)
      end
    end
  end

  private

  def strict_contract
    TestFlightReleaseArtifact::Contract.new(
      bundle_id: BUNDLE_ID,
      version: "1.142.0",
      build_number: "42",
      team_id: TEAM_ID,
      signing_certificate_sha256: CERTIFICATE_SHA256,
      provisioning_profile_uuids: PROFILE_UUIDS
    )
  end

  def assert_strict_snapshot_rejected
    with_source_ipa do |source, temporary_root|
      contract = strict_contract
      metadata = FakeArchiveMetadata.new(contract)
      codesign = FakeCodeSignVerifier.new
      yield metadata, codesign

      assert_raises(TestFlightReleaseArtifact::InvalidArtifact) do
        TestFlightReleaseArtifact::Snapshot.create(
          source_path: source,
          contract: contract,
          archive_metadata: metadata,
          codesign_verifier: codesign,
          temporary_root: temporary_root
        )
      end
      assert_empty Dir.children(temporary_root)
    end
  end

  def create_snapshot(source, temporary_root:, metadata: METADATA)
    TestFlightReleaseArtifact::Snapshot.create(
      source_path: source,
      bundle_id: METADATA.fetch("CFBundleIdentifier"),
      version: METADATA.fetch("CFBundleShortVersionString"),
      build_number: METADATA.fetch("CFBundleVersion"),
      metadata_reader: ->(_path, key) { metadata[key] },
      temporary_root: temporary_root
    )
  end

  def with_source_ipa
    Dir.mktmpdir do |directory|
      source = File.join(directory, "source.ipa")
      temporary_root = File.join(directory, "snapshots")
      Dir.mkdir(temporary_root, 0o700)
      File.binwrite(source, "representative ipa bytes")
      yield source, temporary_root
    end
  end
end

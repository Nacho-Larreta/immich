# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../exact_release_runtime"

class ExactReleaseRuntimeTest < Minitest::Test
  BUNDLE_ID = "com.nacholarreta.nachofotos"
  TEAM_ID = "32NS8MR6UA"
  CERTIFICATE_BYTES = "certificate bytes"
  CERTIFICATE_SHA256 = Digest::SHA256.hexdigest(CERTIFICATE_BYTES)
  PROFILE_UUIDS = {
    BUNDLE_ID => "11111111-1111-4111-8111-111111111111",
    "#{BUNDLE_ID}.ShareExtension" => "22222222-2222-4222-8222-222222222222",
    "#{BUNDLE_ID}.WidgetExtension" => "33333333-3333-4333-8333-333333333333"
  }.freeze

  Plan = Struct.new(
    :developer_portal_team_id,
    :keychain_name,
    :version,
    :build_number,
    :signing_certificate_sha256,
    :profiles,
    keyword_init: true
  )
  Profile = Struct.new(:target, :bundle_id, :path, keyword_init: true)
  ProfilePlan = Struct.new(:profiles, :signing_certificate_sha256, keyword_init: true)
  SigningIdentity = Struct.new(:keychain_name, :certificate_sha1, :certificate_sha256, keyword_init: true)

  class BuildSettingsRunner
    attr_reader :calls

    def initialize(stdout:, exit_status: 0)
      @stdout = stdout
      @exit_status = exit_status
      @calls = []
    end

    def call(argv)
      @calls << argv
      ExactReleaseRuntime::CommandResult.new(stdout: @stdout, stderr: "private stderr", exit_status: @exit_status)
    end
  end

  class FakeArtifactRunner
    attr_reader :calls, :certificate_paths

    def initialize(contract)
      @contract = contract
      @calls = []
      @certificate_paths = []
    end

    def call(argv)
      @calls << argv
      if argv[0..2] == ["/usr/bin/ditto", "-x", "-k"]
        extract_contract_bundles(argv.fetch(4))
      elsif argv[0..1] == ["/usr/bin/codesign", "-d"] && argv.fetch(2).start_with?("--extract-certificates=")
        prefix = argv.fetch(2).delete_prefix("--extract-certificates=")
        @certificate_paths.concat(["#{prefix}0", "#{prefix}1"])
        File.binwrite(@certificate_paths[-2], CERTIFICATE_BYTES)
        File.binwrite(@certificate_paths[-1], "intermediate certificate bytes")
      end

      stdout = case argv[0..3]
               when ["/usr/bin/codesign", "-d", "--entitlements", ":-"]
                 entitlements_plist(argv.fetch(4))
               when ["/usr/bin/security", "cms", "-D", "-i"]
                 embedded_profile_plist(argv.fetch(4))
               else
                 ""
               end
      ExactReleaseRuntime::CommandResult.new(stdout: stdout, stderr: "", exit_status: 0)
    end

    private

    def extract_contract_bundles(root)
      @contract.bundles.each do |bundle|
        path = File.join(root, bundle.archive_path)
        FileUtils.mkdir_p(path)
        File.binwrite(File.join(path, "Info.plist"), info_plist(bundle))
        File.binwrite(File.join(path, "embedded.mobileprovision"), "profile")
      end
    end

    def info_plist(bundle)
      plist(
        "CFBundleIdentifier" => bundle.bundle_id,
        "CFBundleShortVersionString" => @contract.version,
        "CFBundleVersion" => @contract.build_number,
        "ITSAppUsesNonExemptEncryption" => false
      )
    end

    def entitlements_plist(bundle_path)
      bundle = @contract.bundles.find { |candidate| bundle_path.end_with?(candidate.archive_path) }
      plist(
        "com.apple.developer.team-identifier" => TEAM_ID,
        "application-identifier" => bundle.application_identifier
      )
    end

    def embedded_profile_plist(bundle_path)
      bundle = @contract.bundles.find { |candidate| bundle_path.end_with?(candidate.archive_path + "/embedded.mobileprovision") }
      plist("UUID" => bundle.provisioning_profile_uuid)
    end

    def plist(values)
      entries = values.map do |key, value|
        encoded_value = value == false ? "<false/>" : "<string>#{value}</string>"
        "<key>#{key}</key>#{encoded_value}"
      end.join
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " \
        "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
        "<plist version=\"1.0\"><dict>#{entries}</dict></plist>"
    end
  end

  class RecordingProfileDecoder
    attr_reader :paths

    def initialize(contract:, local_profiles:)
      @contract = contract
      @local_profiles = local_profiles
      @paths = []
    end

    def call(path)
      @paths << path
      return @local_profiles.fetch(path) if @local_profiles.key?(path)

      bundle = @contract.bundles.find do |candidate|
        path.end_with?("#{candidate.archive_path}/embedded.mobileprovision")
      end
      { "UUID" => bundle&.provisioning_profile_uuid }
    end
  end

  def test_build_and_snapshot_validation_share_the_exact_contract_without_real_commands
    Dir.mktmpdir do |directory|
      ipa = File.join(directory, "release.ipa")
      create_ipa(ipa)
      File.chmod(0o600, ipa)
      contract = contract()
      runner = FakeArtifactRunner.new(contract)
      service = service(argv_runner: runner)

      assert service.validate_exact_ipa!(ipa, contract)
      snapshot = service.snapshot_exact_ipa!(ipa, contract)

      assert snapshot.verify_unchanged!
      assert_equal 0o600, File.stat(snapshot.path).mode & 0o777
      assert runner.calls.all?(&:frozen?)
      assert runner.calls.flatten.all?(&:frozen?)
      assert_equal 2, runner.calls.count { |argv| argv[0..2] == ["/usr/bin/ditto", "-x", "-k"] }
      assert_equal 6, runner.calls.count { |argv| argv[0..3] == ["/usr/bin/codesign", "--verify", "--deep", "--strict"] }
      snapshot.cleanup!
    end
  end

  def test_private_runtime_xcconfig_binds_each_target_and_is_removed_after_success
    runner = BuildSettingsRunner.new(stdout: exact_build_settings)
    runtime = service(argv_runner: runner)
    captured_path = nil

    result = runtime.with_verified_archive_signing_configuration(
      plan: archive_plan,
      profile_uuids: PROFILE_UUIDS,
      installed_identity: exact_identity
    ) do |arguments|
      values = Shellwords.split(arguments)
      assert_equal "-xcconfig", values.fetch(0)
      captured_path = values.fetch(1)
      file_stat = File.lstat(captured_path)
      directory_stat = File.lstat(File.dirname(captured_path))
      assert file_stat.file?
      refute file_stat.symlink?
      assert_equal 1, file_stat.nlink
      assert_equal Process.euid, file_stat.uid
      assert_equal 0o600, file_stat.mode & 0o777
      assert directory_stat.directory?
      refute directory_stat.symlink?
      assert_equal Process.euid, directory_stat.uid
      assert_equal 0o700, directory_stat.mode & 0o777
      config = File.read(captured_path)
      assert_includes config, "CODE_SIGN_STYLE = Manual"
      assert_includes config, "CODE_SIGN_IDENTITY = #{'a' * 40}"
      assert_includes config, "PROVISIONING_PROFILE_SPECIFIER = $(IMMICH_PROFILE_UUID_$(TARGET_NAME))"
      PROFILE_UUIDS.each_value { |uuid| assert_includes config, uuid }
      refute_includes config, "Apple Distribution"
      :archived
    end

    assert_equal :archived, result
    refute_path_exists captured_path
    refute_path_exists File.dirname(captured_path)
    probe = runner.calls.fetch(0)
    assert_equal "/usr/bin/xcodebuild", probe.fetch(0)
    assert_equal ["-workspace", File.join(ExactReleaseRuntime::IOS_PROJECT_ROOT, "Runner.xcworkspace")], probe[1, 2]
    assert_equal ["-destination", "generic/platform=iOS"], probe[7, 2]
    assert_equal "-showBuildSettings", probe.fetch(9)
    assert_equal ["-xcconfig", captured_path], probe.last(2)
    assert probe.frozen?
    assert probe.all?(&:frozen?)
  end

  def test_runtime_xcconfig_is_removed_when_probe_or_archive_fails
    failed_probe = BuildSettingsRunner.new(stdout: "", exit_status: 1)
    runtime = service(argv_runner: failed_probe)
    assert_raises(ExactReleaseRuntime::Error) do
      runtime.with_verified_archive_signing_configuration(
        plan: archive_plan,
        profile_uuids: PROFILE_UUIDS,
        installed_identity: exact_identity
      ) { flunk "archive must not start" }
    end
    probe_path = failed_probe.calls.fetch(0).last
    refute_path_exists probe_path
    refute_path_exists File.dirname(probe_path)

    runner = BuildSettingsRunner.new(stdout: exact_build_settings)
    archive_path = nil
    assert_raises(RuntimeError) do
      service(argv_runner: runner).with_verified_archive_signing_configuration(
        plan: archive_plan,
        profile_uuids: PROFILE_UUIDS,
        installed_identity: exact_identity
      ) do |arguments|
        archive_path = Shellwords.split(arguments).last
        raise "archive failed"
      end
    end
    refute_path_exists archive_path
    refute_path_exists File.dirname(archive_path)
  end

  def test_runtime_configuration_preserves_the_tracked_configuration_digest
    Dir.mktmpdir do |root|
      tracked_path = File.join(root, "project.pbxproj")
      File.binwrite(tracked_path, "tracked configuration")
      runner = BuildSettingsRunner.new(stdout: exact_build_settings)
      runtime = service(
        argv_runner: runner,
        tracked_paths: ["project.pbxproj"],
        tracked_root: root
      )
      before = runtime.tracked_configuration_digest

      runtime.with_verified_archive_signing_configuration(
        plan: archive_plan,
        profile_uuids: PROFILE_UUIDS,
        installed_identity: exact_identity
      ) { |_arguments| true }

      assert runtime.verify_tracked_configuration_unchanged!(before)
      assert_equal "tracked configuration", File.binread(tracked_path)
    end
  end

  def test_archive_signing_mapping_fails_closed_before_xcodebuild
    invalid_mappings = [
      PROFILE_UUIDS.except(BUNDLE_ID),
      PROFILE_UUIDS.merge("unexpected" => "44444444-4444-4444-8444-444444444444"),
      PROFILE_UUIDS.merge(BUNDLE_ID => PROFILE_UUIDS.fetch("#{BUNDLE_ID}.ShareExtension")),
      PROFILE_UUIDS.merge(BUNDLE_ID => "malformed")
    ]

    invalid_mappings.each do |mapping|
      runner = BuildSettingsRunner.new(stdout: exact_build_settings)
      assert_raises(ExactReleaseRuntime::Error) do
        service(argv_runner: runner).with_verified_archive_signing_configuration(
          plan: archive_plan,
          profile_uuids: mapping,
          installed_identity: exact_identity
        ) { flunk "archive must not start" }
      end
      assert_empty runner.calls
    end
  end

  def test_archive_signing_rejects_an_identity_proof_for_another_plan
    wrong_identities = [
      SigningIdentity.new(
        keychain_name: "other.keychain-db",
        certificate_sha1: "a" * 40,
        certificate_sha256: CERTIFICATE_SHA256
      ),
      SigningIdentity.new(
        keychain_name: "private.keychain-db",
        certificate_sha1: "a" * 40,
        certificate_sha256: "f" * 64
      ),
      SigningIdentity.new(
        keychain_name: "private.keychain-db",
        certificate_sha1: "malformed",
        certificate_sha256: CERTIFICATE_SHA256
      )
    ]

    wrong_identities.each do |identity|
      runner = BuildSettingsRunner.new(stdout: exact_build_settings)
      assert_raises(ExactReleaseRuntime::Error) do
        service(argv_runner: runner).with_verified_archive_signing_configuration(
          plan: archive_plan,
          profile_uuids: PROFILE_UUIDS,
          installed_identity: identity
        ) { flunk "archive must not start" }
      end
      assert_empty runner.calls
    end
  end

  def test_prearchive_probe_rejects_wrong_or_unresolved_exact_settings
    replacements = [
      ["CODE_SIGN_STYLE = Manual", "CODE_SIGN_STYLE = Automatic"],
      ["DEVELOPMENT_TEAM = #{TEAM_ID}", "DEVELOPMENT_TEAM = WRONGTEAM1"],
      ["CODE_SIGN_IDENTITY = #{'a' * 40}", "CODE_SIGN_IDENTITY = #{'b' * 40}"],
      [
        "PROVISIONING_PROFILE_SPECIFIER = #{PROFILE_UUIDS.fetch(BUNDLE_ID)}",
        "PROVISIONING_PROFILE_SPECIFIER = stale tracked profile name"
      ],
      [
        "PROVISIONING_PROFILE_SPECIFIER = #{PROFILE_UUIDS.fetch(BUNDLE_ID)}",
        "PROVISIONING_PROFILE_SPECIFIER = 44444444-4444-4444-8444-444444444444"
      ],
      [
        "PROVISIONING_PROFILE_SPECIFIER = #{PROFILE_UUIDS.fetch(BUNDLE_ID)}",
        "PROVISIONING_PROFILE_SPECIFIER = $(IMMICH_PROFILE_UUID_$(TARGET_NAME))"
      ]
    ]

    replacements.each do |from, to|
      runner = BuildSettingsRunner.new(stdout: exact_build_settings.sub(from, to))
      assert_raises(ExactReleaseRuntime::Error) do
        service(argv_runner: runner).with_verified_archive_signing_configuration(
          plan: archive_plan,
          profile_uuids: PROFILE_UUIDS,
          installed_identity: exact_identity
        ) { flunk "archive must not start" }
      end
    end
  end

  def test_prearchive_probe_rejects_duplicate_and_malformed_target_output
    malformed_outputs = [
      exact_build_settings + exact_build_settings.lines.first(5).join,
      exact_build_settings.sub(
        "    CODE_SIGN_STYLE = Manual\n",
        "    CODE_SIGN_STYLE = Manual\n    CODE_SIGN_STYLE = Manual\n"
      ),
      exact_build_settings.sub("Build settings for action build and target Runner:", "malformed target header")
    ]

    malformed_outputs.each do |stdout|
      assert_raises(ExactReleaseRuntime::Error) do
        service(argv_runner: BuildSettingsRunner.new(stdout: stdout)).with_verified_archive_signing_configuration(
          plan: archive_plan,
          profile_uuids: PROFILE_UUIDS,
          installed_identity: exact_identity
        ) { flunk "archive must not start" }
      end
    end
  end

  def test_runtime_configuration_detects_archive_mutation_and_still_cleans_up
    runner = BuildSettingsRunner.new(stdout: exact_build_settings)
    path = nil

    assert_raises(ExactReleaseRuntime::Error) do
      service(argv_runner: runner).with_verified_archive_signing_configuration(
        plan: archive_plan,
        profile_uuids: PROFILE_UUIDS,
        installed_identity: exact_identity
      ) do |arguments|
        path = Shellwords.split(arguments).last
        File.binwrite(path, "changed")
      end
    end

    refute_path_exists path
    refute_path_exists File.dirname(path)
  end

  def test_signing_certificate_uses_single_codesign_option_and_removes_extracted_output
    Dir.mktmpdir do |directory|
      ipa = File.join(directory, "release.ipa")
      create_ipa(ipa)
      runner = FakeArtifactRunner.new(contract)
      inspection = ExactReleaseRuntime::IpaInspection.new(
        contract: contract,
        argv_runner: runner,
        profile_decoder: MobileProvisionDecoder::Decoder.new(argv_runner: runner)
      )
      bundle = contract.bundles.first

      assert_equal CERTIFICATE_SHA256, inspection.signing_certificate_sha256(ipa, bundle.archive_path)

      certificate_path = runner.certificate_paths.fetch(0)
      prefix = certificate_path.delete_suffix("0")
      assert_equal [
        "/usr/bin/codesign",
        "-d",
        "--extract-certificates=#{prefix}",
        File.join(File.dirname(prefix), bundle.archive_path)
      ], runner.calls.last
      runner.certificate_paths.each { |path| refute_path_exists path }
    ensure
      inspection&.cleanup!
    end
  end

  def test_profile_selection_uses_distinct_uuids_even_when_all_names_are_duplicate
    profiles = PROFILE_UUIDS.each_key.with_index.map do |bundle_id, index|
      Profile.new(bundle_id: bundle_id, path: "/profiles/#{index}.mobileprovision")
    end
    plan = ProfilePlan.new(profiles: profiles, signing_certificate_sha256: CERTIFICATE_SHA256)
    parsed = profiles.each_with_object({}) do |profile, result|
      result[profile.path] = { "Name" => "Duplicate Name", "UUID" => PROFILE_UUIDS.fetch(profile.bundle_id) }
    end
    runtime = ExactReleaseRuntime::Service.new(
      bundle_id: BUNDLE_ID,
      profile_decoder: ->(path) { parsed.fetch(path) },
      argv_runner: Object.new,
      tracked_configuration_paths: []
    )
    verifier = lambda do |path:, expected_bundle_id:, certificate_sha256:, &block|
      assert_equal PROFILE_UUIDS.keys[profiles.index { |profile| profile.path == path }], expected_bundle_id
      assert_equal CERTIFICATE_SHA256, certificate_sha256
      block.call(path)
      true
    end

    result = SigningPreparation::ProfileVerifier.stub(:verify_file!, verifier) do
      runtime.verified_profile_uuids!(plan)
    end

    assert_equal PROFILE_UUIDS, result
    assert result.frozen?
  end

  def test_service_uses_the_same_decoder_for_local_and_embedded_profiles
    profiles = PROFILE_UUIDS.each_key.with_index.map do |bundle_id, index|
      Profile.new(bundle_id: bundle_id, path: "/profiles/#{index}.mobileprovision")
    end
    plan = ProfilePlan.new(profiles: profiles, signing_certificate_sha256: CERTIFICATE_SHA256)
    local_profiles = profiles.to_h do |profile|
      [profile.path, { "UUID" => PROFILE_UUIDS.fetch(profile.bundle_id) }]
    end

    Dir.mktmpdir do |directory|
      ipa = File.join(directory, "release.ipa")
      create_ipa(ipa)
      File.chmod(0o600, ipa)
      release_contract = contract
      runner = FakeArtifactRunner.new(release_contract)
      decoder = RecordingProfileDecoder.new(contract: release_contract, local_profiles: local_profiles)
      runtime = ExactReleaseRuntime::Service.new(
        bundle_id: BUNDLE_ID,
        profile_decoder: decoder,
        argv_runner: runner,
        tracked_configuration_paths: []
      )
      verifier = lambda do |path:, expected_bundle_id:, certificate_sha256:, &block|
        assert_equal PROFILE_UUIDS.fetch(expected_bundle_id), block.call(path).fetch("UUID")
        assert_equal CERTIFICATE_SHA256, certificate_sha256
        true
      end

      SigningPreparation::ProfileVerifier.stub(:verify_file!, verifier) do
        assert_equal PROFILE_UUIDS, runtime.verified_profile_uuids!(plan)
      end
      assert runtime.validate_exact_ipa!(ipa, release_contract)

      assert_equal profiles.map(&:path), decoder.paths.first(3)
      assert_equal release_contract.bundles.map(&:archive_path).sort,
                   decoder.paths.drop(3).map { |path| embedded_archive_path(path) }.sort
    end
  end

  def test_service_translates_profile_decoder_failure_to_its_sanitized_error
    profile = Profile.new(bundle_id: BUNDLE_ID, path: "/private/profile.mobileprovision")
    plan = ProfilePlan.new(profiles: [profile], signing_certificate_sha256: CERTIFICATE_SHA256)
    failing_decoder = lambda do |_path|
      raise MobileProvisionDecoder::Error, "backend detail"
    end
    runtime = ExactReleaseRuntime::Service.new(
      bundle_id: BUNDLE_ID,
      profile_decoder: failing_decoder,
      argv_runner: Object.new,
      tracked_configuration_paths: []
    )
    verifier = lambda do |path:, expected_bundle_id:, certificate_sha256:, &block|
      block.call(path)
    end

    error = SigningPreparation::ProfileVerifier.stub(:verify_file!, verifier) do
      assert_raises(ExactReleaseRuntime::Error) { runtime.verified_profile_uuids!(plan) }
    end

    assert_equal "Provisioning profile could not be decoded", error.message
    refute_includes error.message, "backend detail"
  end

  def test_ipa_inspection_translates_profile_decoder_failure_to_its_sanitized_error
    Dir.mktmpdir do |directory|
      ipa = File.join(directory, "release.ipa")
      create_ipa(ipa)
      runner = FakeArtifactRunner.new(contract)
      failing_decoder = lambda do |_path|
        raise MobileProvisionDecoder::Error, "backend detail"
      end
      inspection = ExactReleaseRuntime::IpaInspection.new(
        contract: contract,
        argv_runner: runner,
        profile_decoder: failing_decoder
      )

      error = assert_raises(ExactReleaseRuntime::Error) do
        inspection.provisioning_profile_uuid(ipa, contract.bundles.first.archive_path)
      end

      assert_equal "Embedded provisioning profile could not be decoded", error.message
      refute_includes error.message, "backend detail"
    ensure
      inspection&.cleanup!
    end
  end

  def test_archive_preflight_rejects_symlink_and_special_entries_before_ditto
    [zip_entry(:symlink), zip_entry(:special)].each do |entry|
      assert_archive_preflight_rejected([entry])
    end
  end

  def test_archive_preflight_rejects_too_many_entries_before_ditto
    entries = RepeatingEntries.new(
      zip_entry(:file),
      ExactReleaseRuntime::IpaInspection::MAX_ENTRY_COUNT + 1
    )

    assert_archive_preflight_rejected(entries)
  end

  def test_archive_preflight_rejects_oversized_total_before_ditto
    entry = zip_entry(:file)
    entry.size = ExactReleaseRuntime::IpaInspection::MAX_TOTAL_UNCOMPRESSED_BYTES + 1

    assert_archive_preflight_rejected([entry])
  end

  def test_tracked_configuration_digest_is_independent_from_cwd_and_detects_delta
    assert_equal File.expand_path("../..", __dir__), ExactReleaseRuntime::IOS_PROJECT_ROOT

    Dir.mktmpdir do |directory|
      unrelated = Dir.mktmpdir
      first = File.join(directory, "first")
      second = File.join(directory, "second")
      File.binwrite(first, "one")
      File.binwrite(second, "two")
      runtime = service(
        argv_runner: Object.new,
        tracked_paths: %w[first second],
        tracked_root: directory
      )
      before = runtime.tracked_configuration_digest

      Dir.chdir(unrelated) do
        assert_equal before, runtime.tracked_configuration_digest
        assert runtime.verify_tracked_configuration_unchanged!(before)
        File.binwrite(second, "changed")
        assert_raises(ExactReleaseRuntime::Error) do
          runtime.verify_tracked_configuration_unchanged!(before)
        end
      end
    ensure
      FileUtils.remove_entry(unrelated) if unrelated && File.exist?(unrelated)
    end
  end

  def test_secure_private_ipa_sets_exact_mode_and_rejects_symlinks
    Dir.mktmpdir do |directory|
      ipa = File.join(directory, "release.ipa")
      symlink = File.join(directory, "linked.ipa")
      File.binwrite(ipa, "ipa")
      File.chmod(0o644, ipa)
      runtime = service(argv_runner: Object.new)

      assert runtime.secure_private_ipa!(ipa)
      assert_equal 0o600, File.stat(ipa).mode & 0o777

      File.symlink(ipa, symlink)
      assert_raises(ExactReleaseRuntime::Error) { runtime.secure_private_ipa!(symlink) }
    end
  end

  private

  def archive_plan
    Plan.new(
      developer_portal_team_id: TEAM_ID,
      keychain_name: "private.keychain-db",
      version: "1.142.0",
      build_number: "42",
      signing_certificate_sha256: CERTIFICATE_SHA256,
      profiles: [
        Profile.new(target: "Runner", bundle_id: BUNDLE_ID),
        Profile.new(target: "ShareExtension", bundle_id: "#{BUNDLE_ID}.ShareExtension"),
        Profile.new(target: "WidgetExtension", bundle_id: "#{BUNDLE_ID}.WidgetExtension")
      ]
    )
  end

  def exact_identity
    SigningIdentity.new(
      keychain_name: "private.keychain-db",
      certificate_sha1: "a" * 40,
      certificate_sha256: CERTIFICATE_SHA256
    )
  end

  def exact_build_settings
    archive_plan.profiles.map do |profile|
      <<~SETTINGS
        Build settings for action build and target #{profile.target}:
            CODE_SIGN_IDENTITY = #{'a' * 40}
            CODE_SIGN_STYLE = Manual
            DEVELOPMENT_TEAM = #{TEAM_ID}
            PROVISIONING_PROFILE_SPECIFIER = #{PROFILE_UUIDS.fetch(profile.bundle_id)}
      SETTINGS
    end.join
  end

  def contract
    TestFlightReleaseArtifact::Contract.new(
      bundle_id: BUNDLE_ID,
      version: "1.142.0",
      build_number: "42",
      team_id: TEAM_ID,
      signing_certificate_sha256: CERTIFICATE_SHA256,
      provisioning_profile_uuids: PROFILE_UUIDS
    )
  end

  RepeatingEntries = Struct.new(:entry, :count) do
    def each
      count.times { yield entry }
    end
  end

  def assert_archive_preflight_rejected(entries)
    runner = FakeArtifactRunner.new(contract)
    inspection = ExactReleaseRuntime::IpaInspection.new(
      contract: contract,
      argv_runner: runner,
      profile_decoder: MobileProvisionDecoder::Decoder.new(argv_runner: runner)
    )

    assert_raises(ExactReleaseRuntime::Error) do
      Zip::File.stub(:open, ->(_path, &block) { block.call(entries) }) do
        inspection.bundle_paths("/private/rejected.ipa")
      end
    end
    assert_empty runner.calls
  ensure
    inspection&.cleanup!
  end

  def zip_entry(type)
    entry = Zip::Entry.new("fixture.zip", "entry")
    entry.size = 1
    entry.fstype = Zip::FSTYPE_UNIX
    file_type = case type
                when :file then Zip::FILE_TYPE_FILE
                when :symlink then Zip::FILE_TYPE_SYMLINK
                else 0o01
                end
    entry.external_file_attributes = file_type << 28
    entry.instance_variable_set(:@ftype, type == :special ? :file : type)
    entry
  end

  def service(argv_runner:, tracked_paths: [], tracked_root: ExactReleaseRuntime::IOS_PROJECT_ROOT)
    ExactReleaseRuntime::Service.new(
      bundle_id: BUNDLE_ID,
      argv_runner: argv_runner,
      tracked_configuration_paths: tracked_paths,
      tracked_configuration_root: tracked_root
    )
  end

  def create_ipa(path)
    Zip::File.open(path, create: true) do |archive|
      archive.get_output_stream("marker") { |stream| stream.write("ipa") }
    end
  end

  def embedded_archive_path(path)
    marker = "Payload/"
    path.delete_prefix(path[0...path.index(marker)]).delete_suffix("/embedded.mobileprovision")
  end
end

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

  Plan = Struct.new(:developer_portal_team_id, :keychain_name, :version, :build_number, keyword_init: true)
  Profile = Struct.new(:bundle_id, :path, keyword_init: true)
  ProfilePlan = Struct.new(:profiles, :signing_certificate_sha256, keyword_init: true)

  class FakeArtifactRunner
    attr_reader :calls

    def initialize(contract)
      @contract = contract
      @calls = []
    end

    def call(argv)
      @calls << argv
      if argv[0..2] == ["/usr/bin/ditto", "-x", "-k"]
        extract_contract_bundles(argv.fetch(4))
      elsif argv[0..2] == ["/usr/bin/codesign", "-d", "--extract-certificates"]
        File.binwrite("#{argv.fetch(3)}0", CERTIFICATE_BYTES)
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

  def test_xcode_arguments_are_shell_escaped_exact_release_values
    plan = Plan.new(
      developer_portal_team_id: TEAM_ID,
      keychain_name: "private.keychain-db",
      version: "1.142.0",
      build_number: "42"
    )

    arguments = service(argv_runner: Object.new).xcode_arguments(
      plan: plan,
      code_sign_identity: "Apple Distribution"
    )

    assert_equal [
      "-skipMacroValidation",
      "CODE_SIGN_STYLE=Manual",
      "CODE_SIGN_IDENTITY=Apple Distribution",
      "DEVELOPMENT_TEAM=#{TEAM_ID}",
      "OTHER_CODE_SIGN_FLAGS=--keychain private.keychain-db",
      "MARKETING_VERSION=1.142.0",
      "CURRENT_PROJECT_VERSION=42"
    ], Shellwords.split(arguments)
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
      profile_parser: ->(path) { parsed.fetch(path) },
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

  def test_tracked_configuration_digest_detects_delta
    Dir.mktmpdir do |directory|
      first = File.join(directory, "first")
      second = File.join(directory, "second")
      File.binwrite(first, "one")
      File.binwrite(second, "two")
      runtime = service(argv_runner: Object.new, tracked_paths: [first, second])
      before = runtime.tracked_configuration_digest

      assert runtime.verify_tracked_configuration_unchanged!(before)
      File.binwrite(second, "changed")
      assert_raises(ExactReleaseRuntime::Error) do
        runtime.verify_tracked_configuration_unchanged!(before)
      end
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
    inspection = ExactReleaseRuntime::IpaInspection.new(contract: contract, argv_runner: runner)

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

  def service(argv_runner:, tracked_paths: [])
    ExactReleaseRuntime::Service.new(
      bundle_id: BUNDLE_ID,
      profile_parser: ->(_path) { raise "not used" },
      argv_runner: argv_runner,
      tracked_configuration_paths: tracked_paths
    )
  end

  def create_ipa(path)
    Zip::File.open(path, create: true) do |archive|
      archive.get_output_stream("marker") { |stream| stream.write("ipa") }
    end
  end
end

# frozen_string_literal: true

require "cfpropertylist"
require "digest"
require "fileutils"
require "find"
require "open3"
require "shellwords"
require "tmpdir"
require "zip"
require_relative "installed_signing_identity"
require_relative "mobileprovision_decoder"
require_relative "signing_preparation"
require_relative "testflight_release_artifact"

module ExactReleaseRuntime
  class Error < StandardError; end

  IOS_PROJECT_ROOT = File.expand_path("..", __dir__).freeze
  TRACKED_CONFIGURATION_PATHS = %w[
    Flutter/Release.xcconfig
    Podfile
    Podfile.lock
    Runner/Info.plist
    Runner.xcodeproj/project.pbxproj
    Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme
    ShareExtension/Info.plist
    WidgetExtension/Info.plist
  ].map(&:freeze).freeze

  CommandResult = Struct.new(:stdout, :stderr, :exit_status, keyword_init: true) do
    def initialize(**values)
      super
      freeze
    end
  end

  class ArchiveSigningBinding
    TARGETS = %w[Runner ShareExtension WidgetExtension].map(&:freeze).freeze
    SHA1 = /\A[0-9a-f]{40}\z/
    SHA256 = /\A[0-9a-f]{64}\z/
    TEAM_ID = /\A[A-Z0-9]{10}\z/
    PROFILE_UUID = TestFlightReleaseArtifact::Contract::PROFILE_UUID
    VERSION = /\A(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\z/
    BUILD_NUMBER = /\A[1-9][0-9]*\z/
    KEYCHAIN_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/

    attr_reader :certificate_sha1, :profile_uuid_by_target

    def initialize(plan:, profile_uuids:, installed_identity:)
      @team_id = validated_string(plan, :developer_portal_team_id, pattern: TEAM_ID)
      @keychain_name = validated_string(plan, :keychain_name, pattern: KEYCHAIN_NAME)
      @version = validated_string(plan, :version, pattern: VERSION)
      @build_number = validated_string(plan, :build_number, pattern: BUILD_NUMBER)
      certificate_sha256 = validated_string(plan, :signing_certificate_sha256, pattern: SHA256)
      @certificate_sha1 = validated_string(installed_identity, :certificate_sha1, pattern: SHA1)
      verified_keychain = validated_string(installed_identity, :keychain_name, pattern: KEYCHAIN_NAME)
      verified_sha256 = validated_string(installed_identity, :certificate_sha256, pattern: SHA256)
      unless verified_keychain == @keychain_name && verified_sha256 == certificate_sha256
        raise Error, "Installed signing identity does not match the archive plan"
      end
      @profile_uuid_by_target = validated_profile_mapping(plan, profile_uuids)
      freeze
    rescue Error
      raise
    rescue StandardError
      raise Error, "Archive signing inputs are invalid"
    end

    def content
      lines = [
        "CODE_SIGN_STYLE = Manual",
        "DEVELOPMENT_TEAM = #{@team_id}",
        "CODE_SIGN_IDENTITY = #{@certificate_sha1}",
        "OTHER_CODE_SIGN_FLAGS = --keychain #{@keychain_name}",
        "MARKETING_VERSION = #{@version}",
        "CURRENT_PROJECT_VERSION = #{@build_number}"
      ]
      TARGETS.each do |target|
        lines << "IMMICH_PROFILE_UUID_#{target} = #{@profile_uuid_by_target.fetch(target)}"
      end
      lines << "PROVISIONING_PROFILE_SPECIFIER = $(IMMICH_PROFILE_UUID_$(TARGET_NAME))"
      "#{lines.join("\n")}\n".freeze
    end

    def expected_settings(target)
      {
        "CODE_SIGN_STYLE" => "Manual",
        "DEVELOPMENT_TEAM" => @team_id,
        "CODE_SIGN_IDENTITY" => @certificate_sha1,
        "PROVISIONING_PROFILE_SPECIFIER" => @profile_uuid_by_target.fetch(target)
      }.transform_values { |value| value.dup.freeze }.freeze
    rescue KeyError
      raise Error, "Archive build settings contain an unexpected target"
    end

    private

    def validated_string(source, attribute, pattern: nil)
      value = source.public_send(attribute)
      valid = value.is_a?(String) && !value.empty? && value == value.strip
      valid &&= value.match?(pattern) if pattern
      raise Error, "Archive signing inputs are invalid" unless valid

      value.dup.freeze
    end

    def validated_profile_mapping(plan, profile_uuids)
      profiles = plan.profiles
      unless profiles.is_a?(Array) && profiles.length == TARGETS.length && profile_uuids.is_a?(Hash)
        raise Error, "Archive profile mapping must contain exactly three targets"
      end

      targets = profiles.map(&:target)
      bundle_ids = profiles.map(&:bundle_id)
      unless targets.sort == TARGETS.sort && targets.uniq.length == TARGETS.length &&
             profile_uuids.keys.sort == bundle_ids.sort
        raise Error, "Archive profile mapping must contain exactly three targets"
      end

      mapping = profiles.to_h do |profile|
        uuid = profile_uuids.fetch(profile.bundle_id)
        unless uuid.is_a?(String) && uuid.match?(PROFILE_UUID)
          raise Error, "Archive profile mapping contains an invalid UUID"
        end

        [profile.target.dup.freeze, uuid.dup.freeze]
      end
      unless mapping.values.uniq.length == TARGETS.length
        raise Error, "Archive profile mapping must use three distinct UUIDs"
      end

      mapping.freeze
    end
  end

  class PrivateRuntimeXcconfig
    FILE_NAME = "ExactRelease.xcconfig"

    attr_reader :path

    def initialize(content)
      @directory = Dir.mktmpdir("immich-exact-signing-")
      File.chmod(0o700, @directory)
      @directory_stat = secure_directory_stat!
      @path = File.join(@directory, FILE_NAME).freeze
      write_once!(content)
      @file_stat = secure_file_stat!
      @digest = Digest::SHA256.file(@path).hexdigest.freeze
    rescue Error
      cleanup_after_initialization_failure
      raise
    rescue StandardError
      cleanup_after_initialization_failure
      raise Error, "Private archive signing configuration could not be created"
    end

    def xcode_arguments
      Shellwords.join(["-xcconfig", @path])
    end

    def verify_unchanged!
      current = secure_file_stat!
      unchanged = current.dev == @file_stat.dev && current.ino == @file_stat.ino &&
                  current.size == @file_stat.size && Digest::SHA256.file(@path).hexdigest == @digest
      raise Error, "Private archive signing configuration changed during the build" unless unchanged

      true
    rescue Error
      raise
    rescue StandardError
      raise Error, "Private archive signing configuration is unavailable"
    end

    def cleanup!
      return true unless @directory

      current = File.lstat(@directory)
      unless current.directory? && !current.symlink? && current.dev == @directory_stat.dev &&
             current.ino == @directory_stat.ino && current.uid == Process.euid
        raise Error, "Private archive signing directory changed before cleanup"
      end

      FileUtils.remove_entry_secure(@directory)
      raise Error, "Private archive signing directory cleanup failed" if File.exist?(@directory) || File.symlink?(@directory)

      @directory = nil
      true
    rescue Error
      raise
    rescue StandardError
      raise Error, "Private archive signing directory cleanup failed"
    end

    private

    def write_once!(content)
      unless content.is_a?(String) && !content.empty? && content.valid_encoding?
        raise Error, "Private archive signing configuration is invalid"
      end

      flags = File::WRONLY | File::CREAT | File::EXCL
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(@path, flags, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.chmod(0o600, @path)
    end

    def secure_directory_stat!
      stat = File.lstat(@directory)
      valid = stat.directory? && !stat.symlink? && stat.uid == Process.euid && stat.mode & 0o777 == 0o700
      raise Error, "Private archive signing directory is invalid" unless valid

      stat
    end

    def secure_file_stat!
      stat = File.lstat(@path)
      valid = stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.euid &&
              stat.mode & 0o777 == 0o600 && stat.size.positive?
      raise Error, "Private archive signing configuration is invalid" unless valid

      stat
    end

    def cleanup_after_initialization_failure
      return unless @directory && File.directory?(@directory) && !File.symlink?(@directory)

      FileUtils.remove_entry_secure(@directory)
    rescue StandardError
      nil
    end
  end

  class BuildSettingsProbe
    XCODEBUILD = "/usr/bin/xcodebuild"
    MAX_OUTPUT_BYTES = 16 * 1024 * 1024
    TARGET_HEADER = /\ABuild settings for action build and target (.+):\z/
    SETTING = /\A\s+([A-Z0-9_]+) = (.*)\z/
    REQUIRED_KEYS = %w[
      CODE_SIGN_IDENTITY
      CODE_SIGN_STYLE
      DEVELOPMENT_TEAM
      PROVISIONING_PROFILE_SPECIFIER
    ].map(&:freeze).freeze

    def initialize(argv_runner:, project_root:)
      @argv_runner = argv_runner
      @project_root = project_root
    end

    def verify!(xcconfig:, binding:)
      result = @argv_runner.call(command(xcconfig.path))
      unless valid_result?(result)
        raise Error, "Archive build settings probe failed"
      end

      settings = parse(result.stdout)
      ArchiveSigningBinding::TARGETS.each do |target|
        expected = binding.expected_settings(target)
        actual = settings.fetch(target) do
          raise Error, "Archive build settings are missing a required target"
        end
        unless actual == expected && actual.values.none? { |value| value.include?("$(") }
          raise Error, "Archive build settings do not match the exact signing contract"
        end
      end
      true
    rescue Error
      raise
    rescue StandardError
      raise Error, "Archive build settings probe failed"
    end

    private

    def command(path)
      [
        XCODEBUILD,
        "-workspace", File.join(@project_root, "Runner.xcworkspace"),
        "-scheme", "Runner",
        "-configuration", "Release",
        "-destination", "generic/platform=iOS",
        "-showBuildSettings",
        "-xcconfig", path
      ].map { |argument| argument.dup.freeze }.freeze
    end

    def valid_result?(result)
      result.respond_to?(:stdout) && result.respond_to?(:stderr) && result.respond_to?(:exit_status) &&
        result.stdout.is_a?(String) && result.stdout.valid_encoding? &&
        result.stdout.bytesize <= MAX_OUTPUT_BYTES && result.stderr.is_a?(String) && result.exit_status == 0
    end

    def parse(output)
      target = nil
      settings = {}
      output.each_line do |line|
        stripped = line.strip
        if (header = TARGET_HEADER.match(stripped))
          target = header[1]
          if ArchiveSigningBinding::TARGETS.include?(target)
            raise Error, "Archive build settings contain a duplicate target" if settings.key?(target)

            settings[target] = {}
          end
          next
        end
        next unless target && settings.key?(target)

        match = SETTING.match(line.chomp)
        next unless match && REQUIRED_KEYS.include?(match[1])

        raise Error, "Archive build settings contain a duplicate value" if settings[target].key?(match[1])

        settings[target][match[1]] = match[2].dup.freeze
      end
      settings.each_value(&:freeze)
      settings.freeze
    end
  end

  class ArgvRunner
    def call(argv)
      unless argv.is_a?(Array) && !argv.empty? && argv.all? { |argument| argument.is_a?(String) }
        raise Error, "Release command argv is invalid"
      end

      stdout, stderr, status = Open3.capture3(*argv)
      CommandResult.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
    rescue Error
      raise
    rescue StandardError
      raise Error, "Release command could not be executed"
    end
  end

  class IpaInspection
    DITTO = "/usr/bin/ditto"
    CODESIGN = "/usr/bin/codesign"
    MAX_ENTRY_COUNT = 50_000
    MAX_TOTAL_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024

    def initialize(contract:, argv_runner:, profile_decoder:)
      @contract = contract
      @argv_runner = argv_runner
      @profile_decoder = profile_decoder
      @directory = Dir.mktmpdir("immich-exact-ipa-")
      File.chmod(0o700, @directory)
      @ipa_path = nil
    rescue StandardError
      cleanup!
      raise
    end

    def bundle_paths(ipa_path)
      prepare!(ipa_path)
      paths = []
      Find.find(@directory) do |path|
        next unless File.directory?(path) && (path.end_with?(".app") || path.end_with?(".appex"))

        paths << relative_path(path)
      end
      paths.freeze
    end

    def info_plist(ipa_path, archive_bundle_path)
      prepare!(ipa_path)
      parse_plist_file(File.join(extracted_bundle_path(archive_bundle_path), "Info.plist"))
    end

    def entitlements(ipa_path, archive_bundle_path)
      prepare!(ipa_path)
      bundle_path = extracted_bundle_path(archive_bundle_path)
      result = run!([CODESIGN, "-d", "--entitlements", ":-", bundle_path])
      parse_plist_data(result.stdout)
    end

    def signing_certificate_sha256(ipa_path, archive_bundle_path)
      prepare!(ipa_path)
      bundle_path = extracted_bundle_path(archive_bundle_path)
      prefix = File.join(@directory, "certificate-#{Digest::SHA256.hexdigest(archive_bundle_path)}-")
      run!([CODESIGN, "-d", "--extract-certificates=#{prefix}", bundle_path])
      certificate_path = "#{prefix}0"
      digest_regular_file(certificate_path, "Extracted signing certificate")
    ensure
      remove_extracted_certificates(prefix)
    end

    def provisioning_profile_uuid(ipa_path, archive_bundle_path)
      prepare!(ipa_path)
      profile_path = File.join(extracted_bundle_path(archive_bundle_path), "embedded.mobileprovision")
      profile = regular_owned_file!(profile_path, "Embedded provisioning profile")
      uuid = @profile_decoder.call(profile)["UUID"]
      unless uuid.is_a?(String) && uuid.match?(TestFlightReleaseArtifact::Contract::PROFILE_UUID)
        raise Error, "Embedded provisioning profile UUID is invalid"
      end

      uuid
    rescue MobileProvisionDecoder::Error
      raise Error, "Embedded provisioning profile could not be decoded"
    end

    def verify!(ipa_path, archive_bundle_path)
      prepare!(ipa_path)
      bundle_path = extracted_bundle_path(archive_bundle_path)
      run!(["/usr/bin/codesign", "--verify", "--deep", "--strict", bundle_path])
      true
    end

    def cleanup!
      return unless @directory && File.directory?(@directory) && !File.symlink?(@directory)

      FileUtils.remove_entry_secure(@directory)
    rescue StandardError
      nil
    end

    private

    def prepare!(ipa_path)
      if @ipa_path
        raise Error, "IPA inspection path changed" unless @ipa_path == ipa_path

        return
      end

      validate_archive_entries!(ipa_path)
      run!(["/usr/bin/ditto", "-x", "-k", ipa_path, @directory])
      verify_extracted_tree!
      @ipa_path = ipa_path.dup.freeze
    rescue Error
      raise
    rescue StandardError
      raise Error, "IPA could not be inspected"
    end

    def validate_archive_entries!(ipa_path)
      Zip::File.open(ipa_path) do |archive|
        entry_count = 0
        total_size = 0
        archive.each do |entry|
          entry_count += 1
          raise Error, "IPA archive contains too many entries" if entry_count > MAX_ENTRY_COUNT

          unless entry.size.is_a?(Integer) && entry.size >= 0
            raise Error, "IPA archive entry size is invalid"
          end
          total_size += entry.size
          if total_size > MAX_TOTAL_UNCOMPRESSED_BYTES
            raise Error, "IPA archive uncompressed size exceeds the safety limit"
          end

          name = entry.name
          components = name.split("/", -1)
          valid = name.is_a?(String) && !name.empty? && !name.start_with?("/") && !name.include?("\0") &&
                  components.none? { |component| component == "." || component == ".." }
          raise Error, "IPA contains an unsafe archive entry" unless valid

          next unless entry.fstype == Zip::FSTYPE_UNIX

          file_type = entry.external_file_attributes >> 28
          unless [Zip::FILE_TYPE_FILE, Zip::FILE_TYPE_DIR].include?(file_type)
            raise Error, "IPA contains a symlink or special archive entry"
          end
        end
      end
    end

    def verify_extracted_tree!
      Find.find(@directory) do |path|
        stat = File.lstat(path)
        valid = !stat.symlink? && (stat.directory? || stat.file?) && stat.uid == Process.euid
        raise Error, "IPA extracted an unsafe filesystem entry" unless valid
      end
    end

    def extracted_bundle_path(archive_bundle_path)
      unless @contract.bundles.any? { |bundle| bundle.archive_path == archive_bundle_path }
        raise Error, "IPA bundle path is outside the release contract"
      end

      path = File.join(@directory, archive_bundle_path)
      stat = File.lstat(path)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.euid
        raise Error, "IPA bundle directory is invalid"
      end

      path
    rescue Errno::ENOENT, Errno::EACCES
      raise Error, "IPA bundle directory is unavailable"
    end

    def parse_plist_file(path)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.uid == Process.euid
        raise Error, "IPA plist is invalid"
      end

      CFPropertyList.native_types(CFPropertyList::List.new(file: path).value)
    rescue Error
      raise
    rescue StandardError
      raise Error, "IPA plist could not be parsed"
    end

    def parse_plist_data(data)
      CFPropertyList.native_types(CFPropertyList::List.new(data: data).value)
    rescue StandardError
      raise Error, "IPA entitlements could not be parsed"
    end

    def digest_regular_file(path, description)
      Digest::SHA256.file(regular_owned_file!(path, description)).hexdigest
    rescue Error
      raise
    rescue StandardError
      raise Error, "#{description} is unavailable"
    end

    def regular_owned_file!(path, description)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.euid && stat.size.positive?
        raise Error, "#{description} is invalid"
      end

      path
    rescue Error
      raise
    rescue StandardError
      raise Error, "#{description} is unavailable"
    end

    def remove_extracted_certificates(prefix)
      return unless prefix

      directory = File.dirname(prefix)
      basename = File.basename(prefix)
      Dir.each_child(directory) do |entry|
        next unless entry.match?(/\A#{Regexp.escape(basename)}\d+\z/)

        path = File.join(directory, entry)
        File.unlink(path) if File.file?(path) || File.symlink?(path)
      end
    rescue StandardError
      nil
    end

    def run!(argv)
      frozen_argv = argv.map { |argument| argument.dup.freeze }.freeze
      result = @argv_runner.call(frozen_argv)
      unless result.respond_to?(:stdout) && result.respond_to?(:stderr) && result.respond_to?(:exit_status) &&
             result.stdout.is_a?(String) && result.stderr.is_a?(String) && result.exit_status == 0
        raise Error, "IPA inspection command failed"
      end

      result
    end

    def relative_path(path)
      path.delete_prefix("#{@directory}/")
    end
  end

  class Service
    def initialize(bundle_id:, profile_decoder: nil, argv_runner: ArgvRunner.new,
                   tracked_configuration_paths: TRACKED_CONFIGURATION_PATHS,
                   tracked_configuration_root: IOS_PROJECT_ROOT)
      @bundle_id = bundle_id
      @argv_runner = argv_runner
      @profile_decoder = profile_decoder || MobileProvisionDecoder::Decoder.new(argv_runner: argv_runner)
      @tracked_configuration_root = validated_configuration_root!(tracked_configuration_root)
      @tracked_configuration_paths = validated_configuration_paths!(tracked_configuration_paths)
    end

    def contract(version:, build_number:, developer_portal_team_id:, signing_certificate_sha256:,
                 provisioning_profile_uuids:)
      TestFlightReleaseArtifact::Contract.new(
        bundle_id: @bundle_id,
        version: version,
        build_number: build_number,
        team_id: developer_portal_team_id,
        signing_certificate_sha256: signing_certificate_sha256,
        provisioning_profile_uuids: provisioning_profile_uuids
      )
    end

    def verify_installed_signing_identity!(plan)
      InstalledSigningIdentity::Verifier.new(
        argv_runner: @argv_runner,
        parser: InstalledSigningIdentity::Parser.new
      ).verify!(
        keychain_name: plan.keychain_name,
        expected_sha256: plan.signing_certificate_sha256
      )
    end

    def verified_profile_uuids!(plan)
      uuids = plan.profiles.each_with_object({}) do |profile, result|
        profile_data = nil
        SigningPreparation::ProfileVerifier.verify_file!(
          path: profile.path,
          expected_bundle_id: profile.bundle_id,
          certificate_sha256: plan.signing_certificate_sha256
        ) do |path|
          profile_data = @profile_decoder.call(path)
        end
        uuid = profile_data && profile_data["UUID"]
        unless uuid.is_a?(String) && uuid.match?(TestFlightReleaseArtifact::Contract::PROFILE_UUID)
          raise Error, "Provisioning profile UUID is invalid"
        end

        result[profile.bundle_id] = uuid.dup.freeze
      end
      unless uuids.length == 3 && uuids.values.uniq.length == 3
        raise Error, "Exactly three distinct provisioning profiles are required"
      end

      uuids.freeze
    rescue MobileProvisionDecoder::Error
      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE
    end

    def tracked_configuration_digest
      digest = Digest::SHA256.new
      @tracked_configuration_paths.each do |path|
        digest_tracked_file!(digest, path)
      end
      digest.hexdigest
    rescue Error
      raise
    rescue StandardError
      raise Error, "Tracked build configuration could not be captured"
    end

    def verify_tracked_configuration_unchanged!(before_digest)
      return true if tracked_configuration_digest == before_digest

      raise Error, "Tracked build configuration changed during the production build"
    end

    def secure_private_ipa!(path)
      before = File.lstat(path)
      unless before.file? && !before.symlink? && before.nlink == 1 && before.uid == Process.euid && before.size.positive?
        raise Error, "Built IPA must be an owned non-empty regular file"
      end

      io = File.open(path, File::RDONLY | File::NOFOLLOW)
      opened = io.stat
      unless opened.dev == before.dev && opened.ino == before.ino
        raise Error, "Built IPA changed while it was opened"
      end

      io.chmod(TestFlightReleaseArtifact::Contract::OUTPUT_FILE_MODE)
      after = File.lstat(path)
      verified = io.stat
      unless after.dev == opened.dev && after.ino == opened.ino && verified.mode & 0o777 == 0o600
        raise Error, "Built IPA changed while permissions were secured"
      end

      true
    rescue Error
      raise
    rescue StandardError
      raise Error, "Built IPA could not be secured"
    ensure
      io&.close
    end

    def validate_exact_ipa!(ipa_path, contract)
      with_inspection(contract) do |inspection|
        TestFlightReleaseArtifact::Validator.new(
          contract: contract,
          archive_metadata: inspection,
          codesign_verifier: inspection
        ).validate!(ipa_path)
      end
    end

    def snapshot_exact_ipa!(source_path, contract)
      with_inspection(contract) do |inspection|
        TestFlightReleaseArtifact::Snapshot.create(
          source_path: source_path,
          contract: contract,
          archive_metadata: inspection,
          codesign_verifier: inspection
        )
      end
    end

    def with_verified_archive_signing_configuration(plan:, profile_uuids:, installed_identity:)
      binding = ArchiveSigningBinding.new(
        plan: plan,
        profile_uuids: profile_uuids,
        installed_identity: installed_identity
      )
      xcconfig = PrivateRuntimeXcconfig.new(binding.content)
      begin
        BuildSettingsProbe.new(
          argv_runner: @argv_runner,
          project_root: IOS_PROJECT_ROOT
        ).verify!(xcconfig: xcconfig, binding: binding)
        xcconfig.verify_unchanged!
        result = yield xcconfig.xcode_arguments
        xcconfig.verify_unchanged!
        result
      ensure
        xcconfig.cleanup!
      end
    end

    private

    def with_inspection(contract)
      inspection = IpaInspection.new(
        contract: contract,
        argv_runner: @argv_runner,
        profile_decoder: @profile_decoder
      )
      yield inspection
    ensure
      inspection&.cleanup!
    end

    def digest_tracked_file!(digest, path)
      absolute_path = File.expand_path(path, @tracked_configuration_root)
      io = File.open(absolute_path, File::RDONLY | File::NOFOLLOW)
      opened = io.stat
      raise Error, "Tracked build configuration is invalid" unless opened.file?

      digest.update([path.bytesize].pack("Q>"))
      digest.update(path)
      while (chunk = io.read(1024 * 1024))
        digest.update(chunk)
      end
      after = File.lstat(absolute_path)
      unless after.dev == opened.dev && after.ino == opened.ino && after.size == opened.size
        raise Error, "Tracked build configuration changed while it was read"
      end
    ensure
      io&.close
    end

    def validated_configuration_root!(root)
      expanded = File.expand_path(root)
      stat = File.lstat(expanded)
      unless stat.directory? && !stat.symlink?
        raise Error, "Tracked build configuration root is invalid"
      end

      expanded.freeze
    rescue Error
      raise
    rescue StandardError
      raise Error, "Tracked build configuration root is unavailable"
    end

    def validated_configuration_paths!(paths)
      unless paths.is_a?(Array) && paths.all? { |path| valid_relative_configuration_path?(path) }
        raise Error, "Tracked build configuration paths are invalid"
      end

      paths.map { |path| path.dup.freeze }.freeze
    end

    def valid_relative_configuration_path?(path)
      return false unless path.is_a?(String) && !path.empty? && !path.start_with?("/")

      expanded = File.expand_path(path, @tracked_configuration_root)
      expanded.start_with?("#{@tracked_configuration_root}/") &&
        expanded == File.join(@tracked_configuration_root, path)
    end
  end
end

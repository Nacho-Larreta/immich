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
    SECURITY = "/usr/bin/security"
    MAX_ENTRY_COUNT = 50_000
    MAX_TOTAL_UNCOMPRESSED_BYTES = 2 * 1024 * 1024 * 1024

    def initialize(contract:, argv_runner:)
      @contract = contract
      @argv_runner = argv_runner
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
      result = run!([SECURITY, "cms", "-D", "-i", profile])
      values = parse_plist_data(result.stdout)
      uuid = values["UUID"] if values.is_a?(Hash)
      unless uuid.is_a?(String) && uuid.match?(TestFlightReleaseArtifact::Contract::PROFILE_UUID)
        raise Error, "Embedded provisioning profile UUID is invalid"
      end

      uuid
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
    def initialize(bundle_id:, profile_parser:, argv_runner: ArgvRunner.new,
                   tracked_configuration_paths: TRACKED_CONFIGURATION_PATHS,
                   tracked_configuration_root: IOS_PROJECT_ROOT)
      @bundle_id = bundle_id
      @profile_parser = profile_parser
      @argv_runner = argv_runner
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
          profile_data = @profile_parser.call(path)
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

    def xcode_arguments(plan:, code_sign_identity:)
      Shellwords.join(
        [
          "-skipMacroValidation",
          "CODE_SIGN_STYLE=Manual",
          "CODE_SIGN_IDENTITY=#{code_sign_identity}",
          "DEVELOPMENT_TEAM=#{plan.developer_portal_team_id}",
          "OTHER_CODE_SIGN_FLAGS=--keychain #{plan.keychain_name}",
          "MARKETING_VERSION=#{plan.version}",
          "CURRENT_PROJECT_VERSION=#{plan.build_number}"
        ]
      )
    end

    private

    def with_inspection(contract)
      inspection = IpaInspection.new(contract: contract, argv_runner: @argv_runner)
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

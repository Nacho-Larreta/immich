# frozen_string_literal: true

require "digest"
require "tmpdir"
require_relative "secure_file_operations"

module TestFlightReleaseArtifact
  class InvalidArtifact < ArgumentError; end

  FileIdentity = Struct.new(:device, :inode, :owner, :size, :sha256, keyword_init: true) do
    def initialize(**values)
      super
      freeze
    end
  end

  BundleContract = Struct.new(
    :archive_path,
    :bundle_id,
    :application_identifier,
    :provisioning_profile_uuid,
    keyword_init: true
  ) do
    def initialize(**values)
      super
      each_pair { |name, value| self[name] = value.dup.freeze if value.is_a?(String) }
      freeze
    end
  end

  class Contract
    MAIN_BUNDLE_PATH = "Payload/Nacho Fotos.app"
    SHARE_EXTENSION_PATH = "#{MAIN_BUNDLE_PATH}/PlugIns/ShareExtension.appex"
    WIDGET_EXTENSION_PATH = "#{MAIN_BUNDLE_PATH}/PlugIns/WidgetExtension.appex"
    OUTPUT_FILE_MODE = 0o600
    CERTIFICATE_SHA256 = /\A[0-9a-f]{64}\z/.freeze
    PROFILE_UUID = /\A[0-9A-F]{8}-[0-9A-F]{4}-[1-5][0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\z/i.freeze

    attr_reader :bundle_id, :version, :build_number, :team_id, :signing_certificate_sha256,
                :bundles, :output_file_mode

    def initialize(bundle_id:, version:, build_number:, team_id:, signing_certificate_sha256:,
                   provisioning_profile_uuids:)
      @bundle_id = required_string!(bundle_id, "bundle_id")
      @version = required_string!(version, "version")
      @build_number = required_string!(build_number, "build_number")
      @team_id = required_string!(team_id, "team_id")
      @signing_certificate_sha256 = required_string!(
        signing_certificate_sha256,
        "signing_certificate_sha256"
      )
      unless @signing_certificate_sha256.match?(CERTIFICATE_SHA256)
        raise InvalidArtifact, "Signing certificate fingerprint must be exactly 64 lowercase hexadecimal characters"
      end

      @output_file_mode = OUTPUT_FILE_MODE
      expected_bundle_ids = [
        @bundle_id,
        "#{@bundle_id}.ShareExtension",
        "#{@bundle_id}.WidgetExtension"
      ].freeze
      profile_uuids = validated_profile_uuids!(provisioning_profile_uuids, expected_bundle_ids)
      @bundles = [
        bundle(MAIN_BUNDLE_PATH, expected_bundle_ids.fetch(0), profile_uuids),
        bundle(SHARE_EXTENSION_PATH, expected_bundle_ids.fetch(1), profile_uuids),
        bundle(WIDGET_EXTENSION_PATH, expected_bundle_ids.fetch(2), profile_uuids)
      ].freeze
      freeze
    end

    private

    def required_string!(value, name)
      unless value.is_a?(String) && !value.empty?
        raise InvalidArtifact, "#{name} must be a non-empty string"
      end

      value.dup.freeze
    end

    def validated_profile_uuids!(values, expected_bundle_ids)
      unless values.is_a?(Hash) && values.keys.sort == expected_bundle_ids.sort
        raise InvalidArtifact, "Provisioning profile UUIDs must match the exact release bundles"
      end

      result = expected_bundle_ids.each_with_object({}) do |expected_bundle_id, uuids|
        uuid = values.fetch(expected_bundle_id)
        unless uuid.is_a?(String) && uuid.match?(PROFILE_UUID)
          raise InvalidArtifact, "Provisioning profile UUID is invalid"
        end

        uuids[expected_bundle_id] = uuid.dup.freeze
      end
      unless result.values.uniq.length == expected_bundle_ids.length
        raise InvalidArtifact, "Provisioning profile UUIDs must be distinct"
      end

      result.freeze
    end

    def bundle(archive_path, expected_bundle_id, profile_uuids)
      BundleContract.new(
        archive_path: archive_path,
        bundle_id: expected_bundle_id,
        application_identifier: "#{@team_id}.#{expected_bundle_id}",
        provisioning_profile_uuid: profile_uuids.fetch(expected_bundle_id)
      )
    end
  end

  module PrivateIpaFile
    module_function

    def identity(candidate, expected_mode:)
      before = File.lstat(candidate)
      unless before.file? && !before.symlink? && before.nlink == 1 && before.uid == Process.euid
        raise InvalidArtifact, "Private IPA must remain an owned regular file"
      end
      unless before.mode & 0o777 == expected_mode
        raise InvalidArtifact, "Private IPA permissions changed"
      end

      io = File.open(candidate, File::RDONLY | File::NOFOLLOW)
      opened = io.stat
      unless before.dev == opened.dev && before.ino == opened.ino
        raise InvalidArtifact, "Private IPA changed while it was opened"
      end
      digest = Digest::SHA256.new
      while (chunk = io.read(1024 * 1024))
        digest.update(chunk)
      end
      after = File.lstat(candidate)
      unless after.dev == opened.dev && after.ino == opened.ino
        raise InvalidArtifact, "Private IPA changed while it was read"
      end

      FileIdentity.new(
        device: opened.dev,
        inode: opened.ino,
        owner: opened.uid,
        size: opened.size,
        sha256: digest.hexdigest
      )
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise InvalidArtifact, "Private IPA is unavailable"
    ensure
      io&.close
    end
  end

  class Validator
    def initialize(contract:, archive_metadata:, codesign_verifier:)
      @contract = contract
      @archive_metadata = archive_metadata
      @codesign_verifier = codesign_verifier
    end

    def validate!(ipa_path)
      before = private_file_identity(ipa_path)
      verify_exact_bundles!(ipa_path)
      @contract.bundles.each { |bundle| verify_bundle!(ipa_path, bundle) }
      after = private_file_identity(ipa_path)
      unless after == before
        raise InvalidArtifact, "Private IPA changed during contract validation"
      end

      true
    rescue InvalidArtifact
      raise
    rescue StandardError
      raise InvalidArtifact, "IPA contract metadata could not be verified"
    end

    private

    def private_file_identity(ipa_path)
      PrivateIpaFile.identity(ipa_path, expected_mode: @contract.output_file_mode)
    end

    def verify_exact_bundles!(ipa_path)
      actual = @archive_metadata.bundle_paths(ipa_path)
      expected = @contract.bundles.map(&:archive_path)
      unless actual.is_a?(Array) && actual.all? { |path| path.is_a?(String) } && actual.sort == expected.sort
        raise InvalidArtifact, "IPA must contain exactly the protected app and extensions"
      end
    end

    def verify_bundle!(ipa_path, bundle)
      info = @archive_metadata.info_plist(ipa_path, bundle.archive_path)
      entitlements = @archive_metadata.entitlements(ipa_path, bundle.archive_path)
      unless info.is_a?(Hash) && entitlements.is_a?(Hash)
        raise InvalidArtifact, "IPA bundle metadata is invalid"
      end

      verify_info_plist!(info, bundle)
      verify_entitlements!(entitlements, bundle)
      unless @codesign_verifier.verify!(ipa_path, bundle.archive_path) == true
        raise InvalidArtifact, "IPA bundle failed code signature verification"
      end
      certificate = @archive_metadata.signing_certificate_sha256(ipa_path, bundle.archive_path)
      unless certificate == @contract.signing_certificate_sha256
        raise InvalidArtifact, "IPA bundle signing certificate does not match the protected release"
      end
      profile_uuid = @archive_metadata.provisioning_profile_uuid(ipa_path, bundle.archive_path)
      unless profile_uuid == bundle.provisioning_profile_uuid
        raise InvalidArtifact, "IPA embedded provisioning profile does not match the protected release"
      end
    end

    def verify_info_plist!(info, bundle)
      unless info["CFBundleIdentifier"] == bundle.bundle_id
        raise InvalidArtifact, "IPA bundle ID does not match the protected release"
      end
      unless info["CFBundleShortVersionString"] == @contract.version
        raise InvalidArtifact, "IPA version does not match the protected release"
      end
      unless info["CFBundleVersion"] == @contract.build_number
        raise InvalidArtifact, "IPA build does not match the protected release"
      end
      if bundle.archive_path == Contract::MAIN_BUNDLE_PATH && info["ITSAppUsesNonExemptEncryption"] != false
        raise InvalidArtifact, "IPA encryption declaration must be explicitly false"
      end
    end

    def verify_entitlements!(entitlements, bundle)
      unless entitlements["com.apple.developer.team-identifier"] == @contract.team_id
        raise InvalidArtifact, "IPA bundle team identifier does not match the protected release"
      end
      unless entitlements["application-identifier"] == bundle.application_identifier
        raise InvalidArtifact, "IPA application identifier does not match the protected release"
      end
    end
  end

  class Snapshot
    attr_reader :path

    def self.create(source_path:, bundle_id: nil, version: nil, build_number: nil, metadata_reader: nil,
                    temporary_root: nil, before_partial_cleanup: nil, contract: nil,
                    archive_metadata: nil, codesign_verifier: nil)
      source = open_regular_source(source_path)
      directory = Dir.mktmpdir("immich-testflight-artifact-", temporary_root)
      File.chmod(0o700, directory)
      directory_identity = secure_directory_identity(directory)
      path = File.join(directory, "release.ipa")
      partial_identity = copy_source(source, path)
      snapshot = new(
        directory: directory,
        path: path,
        metadata_reader: metadata_reader,
        bundle_id: bundle_id,
        version: version,
        build_number: build_number,
        contract: contract,
        archive_metadata: archive_metadata,
        codesign_verifier: codesign_verifier
      )
      snapshot
    rescue StandardError
      if snapshot
        snapshot.cleanup!
      else
        cleanup_incomplete(
          directory,
          path,
          directory_identity: directory_identity,
          file_identity: partial_identity,
          before_remove: before_partial_cleanup
        )
      end
      raise
    ensure
      source&.close
    end

    def initialize(directory:, path:, metadata_reader:, bundle_id:, version:, build_number:, contract:,
                   archive_metadata:, codesign_verifier:)
      @directory = directory.freeze
      @path = path.freeze
      @directory_identity = directory_identity(directory)
      @identity = file_identity(path)
      if contract
        Validator.new(
          contract: contract,
          archive_metadata: archive_metadata,
          codesign_verifier: codesign_verifier
        ).validate!(path)
      else
        verify_metadata!(
          metadata_reader: metadata_reader,
          bundle_id: bundle_id,
          version: version,
          build_number: build_number
        )
      end
      freeze
    end

    def verify_unchanged!
      current = file_identity(path)
      unless current == @identity
        raise InvalidArtifact, "Private IPA snapshot changed after validation"
      end

      true
    end

    def cleanup!(before_remove: nil)
      operations = verified_directory_operations
      operations.remove_owned!(
        name: File.basename(path),
        expected_identity: secure_identity(@identity),
        before_operation: before_remove
      )
      operations.close
      operations = nil
      remove_snapshot_directory!
    rescue SecureFileOperations::Error, Errno::ENOENT, Errno::ENOTEMPTY
      nil
    ensure
      operations&.close
    end

    private

    def verify_metadata!(metadata_reader:, bundle_id:, version:, build_number:)
      values = {
        bundle_id: metadata_reader.call(path, "CFBundleIdentifier"),
        version: metadata_reader.call(path, "CFBundleShortVersionString"),
        build_number: metadata_reader.call(path, "CFBundleVersion"),
        encryption: metadata_reader.call(path, "ITSAppUsesNonExemptEncryption")
      }
      unless values[:bundle_id] == bundle_id
        raise InvalidArtifact, "IPA bundle ID does not match the protected release"
      end
      unless values[:version].to_s == version
        raise InvalidArtifact, "IPA version does not match EXPECTED_VERSION"
      end
      unless values[:build_number].to_s == build_number
        raise InvalidArtifact, "IPA build does not match EXPECTED_BUILD_NUMBER"
      end
      unless values[:encryption] == false
        raise InvalidArtifact, "IPA encryption declaration must be explicitly false"
      end

      verify_unchanged!
    end

    def file_identity(candidate)
      PrivateIpaFile.identity(candidate, expected_mode: Contract::OUTPUT_FILE_MODE)
    end

    def directory_identity(candidate)
      stat = File.lstat(candidate)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.euid && stat.mode & 0o777 == 0o700
        raise InvalidArtifact, "Private IPA directory is invalid"
      end

      SecureFileOperations::Identity.new(device: stat.dev, inode: stat.ino, owner: stat.uid)
    end

    def verified_directory_operations
      operations = SecureFileOperations::Directory.new(@directory)
      unless operations.self_identity == @directory_identity
        operations.close
        raise InvalidArtifact, "Private IPA directory changed before cleanup"
      end
      operations
    end

    def remove_snapshot_directory!
      parent = File.dirname(@directory)
      operations = SecureFileOperations::Directory.new(parent)
      operations.remove_owned_directory!(
        name: File.basename(@directory),
        expected_identity: secure_identity(@directory_identity)
      )
    ensure
      operations&.close
    end

    def secure_identity(identity)
      SecureFileOperations::Identity.new(
        device: identity.device,
        inode: identity.inode,
        owner: identity.owner
      )
    end

    class << self
      private

      def open_regular_source(path)
        raise InvalidArtifact, "IPA_PATH must have the .ipa extension" unless File.extname(path.to_s).downcase == ".ipa"

        io = File.open(path, File::RDONLY | File::NOFOLLOW)
        stat = io.stat
        unless stat.file? && stat.size.positive?
          io.close
          raise InvalidArtifact, "IPA_PATH must point to a non-empty regular file"
        end
        io
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        raise InvalidArtifact, "IPA_PATH must point to an accessible regular file"
      end

      def copy_source(source, destination)
        File.open(destination, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, 0o600) do |target|
          target.chmod(Contract::OUTPUT_FILE_MODE)
          IO.copy_stream(source, target)
          target.flush
          target.fsync
          stat = target.stat
          return SecureFileOperations::Identity.new(device: stat.dev, inode: stat.ino, owner: stat.uid)
        end
      end

      def secure_directory_identity(directory)
        operations = SecureFileOperations::Directory.new(directory)
        operations.self_identity
      ensure
        operations&.close
      end

      def cleanup_incomplete(directory, path, directory_identity:, file_identity:, before_remove:)
        return unless directory && path && directory_identity && file_identity

        operations = SecureFileOperations::Directory.new(directory)
        return unless operations.self_identity == directory_identity

        operations.remove_owned!(
          name: File.basename(path),
          expected_identity: file_identity,
          before_operation: before_remove
        )
        operations.close
        operations = nil
        parent_operations = SecureFileOperations::Directory.new(File.dirname(directory))
        parent_operations.remove_owned_directory!(
          name: File.basename(directory),
          expected_identity: directory_identity
        )
      rescue SecureFileOperations::Error, Errno::ENOENT, Errno::ENOTEMPTY
        nil
      ensure
        operations&.close
        parent_operations&.close
      end
    end
  end
end

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

  class Snapshot
    attr_reader :path

    def self.create(source_path:, bundle_id:, version:, build_number:, metadata_reader:, temporary_root: nil,
                    before_partial_cleanup: nil)
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
        build_number: build_number
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

    def initialize(directory:, path:, metadata_reader:, bundle_id:, version:, build_number:)
      @directory = directory.freeze
      @path = path.freeze
      @directory_identity = directory_identity(directory)
      @identity = file_identity(path)
      verify_metadata!(
        metadata_reader: metadata_reader,
        bundle_id: bundle_id,
        version: version,
        build_number: build_number
      )
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
      before = File.lstat(candidate)
      unless before.file? && !before.symlink? && before.nlink == 1 && before.uid == Process.euid
        raise InvalidArtifact, "Private IPA snapshot must remain an owned regular file"
      end
      raise InvalidArtifact, "Private IPA snapshot permissions changed" unless before.mode & 0o777 == 0o600

      io = File.open(candidate, File::RDONLY | File::NOFOLLOW)
      opened = io.stat
      unless before.dev == opened.dev && before.ino == opened.ino
        raise InvalidArtifact, "Private IPA snapshot changed while it was opened"
      end
      digest = Digest::SHA256.new
      while (chunk = io.read(1024 * 1024))
        digest.update(chunk)
      end
      after = File.lstat(candidate)
      unless after.dev == opened.dev && after.ino == opened.ino
        raise InvalidArtifact, "Private IPA snapshot changed while it was read"
      end

      FileIdentity.new(
        device: opened.dev,
        inode: opened.ino,
        owner: opened.uid,
        size: opened.size,
        sha256: digest.hexdigest
      )
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise InvalidArtifact, "Private IPA snapshot is unavailable"
    ensure
      io&.close
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

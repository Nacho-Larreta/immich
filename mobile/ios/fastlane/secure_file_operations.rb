# frozen_string_literal: true

require "ffi"
require "securerandom"

module SecureFileOperations
  class Error < StandardError; end
  class RaceLost < Error; end

  Identity = Struct.new(:device, :inode, :owner, keyword_init: true) do
    def initialize(**values)
      super
      freeze
    end
  end

  module Darwin
    extend FFI::Library
    ffi_lib FFI::Library::LIBC
    attach_function :openat, [:int, :string, :int, :int], :int
    attach_function :unlinkat, [:int, :string, :int], :int
    attach_function :renameatx_np, [:int, :string, :int, :string, :uint], :int
  end

  class Directory
    RENAME_EXCL = 0x00000004
    RENAME_NOFOLLOW_ANY = 0x00000010
    RENAME_RESOLVE_BENEATH = 0x00000020
    SECURE_RENAME_FLAGS = RENAME_EXCL | RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH

    def initialize(path)
      @io = File.open(path, File::RDONLY | File::NOFOLLOW)
      stat = @io.stat
      unless stat.directory? && stat.uid == Process.euid && stat.mode & 0o077 == 0
        raise Error, "Secure file directory must be private and owned by the current user"
      end
      @self_identity = Identity.new(device: stat.dev, inode: stat.ino, owner: stat.uid)
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise Error, "Secure file directory is unavailable"
    end

    def close
      @io&.close
    end

    attr_reader :self_identity

    def identity(name)
      entry_identity(name, :file)
    end

    def directory_identity(name)
      entry_identity(name, :directory)
    end

    def remove_owned_directory!(name:, expected_identity:, before_operation: nil)
      quarantine = quarantine_name
      before_operation&.call
      rename_exclusive!(name, quarantine)
      displaced = directory_identity(quarantine)
      unless same_identity?(displaced, expected_identity)
        restore_racer!(quarantine, name, displaced, kind: :directory)
        raise RaceLost, "Secure directory remove lost a destination race"
      end

      unlink_random_owned!(quarantine, expected_identity, directory: true)
      true
    end

    def entry_identity(name, kind)
      validate_name!(name)
      fd = Darwin.openat(@io.fileno, name, File::RDONLY | File::NOFOLLOW, 0)
      raise_system_call!("openat") if fd.negative?

      io = IO.for_fd(fd)
      stat = io.stat
      expected_kind = kind == :directory ? stat.directory? : stat.file? && stat.nlink == 1
      unless expected_kind && stat.uid == Process.euid
        raise Error, "Secure entry has an unexpected type or owner"
      end

      Identity.new(device: stat.dev, inode: stat.ino, owner: stat.uid)
    rescue Errno::ELOOP
      raise Error, "Secure file must not be a symlink"
    ensure
      io&.close
    end

    def replace_owned!(final_name:, staging_name:, expected_final:, expected_staging:, before_operation: nil)
      quarantine = quarantine_name
      before_operation&.call
      rename_exclusive!(final_name, quarantine)
      displaced = identity(quarantine)
      unless same_identity?(displaced, expected_final)
        restore_racer!(quarantine, final_name, displaced)
        raise RaceLost, "Secure replace lost a destination race"
      end

      begin
        rename_exclusive!(staging_name, final_name)
      rescue Error => error
        unlink_random_owned!(quarantine, expected_final)
        raise RaceLost, "Secure replace destination was recreated: #{error.class.name.split('::').last}"
      end

      published = identity(final_name)
      unless same_identity?(published, expected_staging)
        unlink_random_owned!(quarantine, expected_final)
        raise RaceLost, "Secure replace could not verify the published inode"
      end

      unlink_random_owned!(quarantine, expected_final)
      published
    end

    def remove_owned!(name:, expected_identity:, before_operation: nil)
      quarantine = quarantine_name
      before_operation&.call
      rename_exclusive!(name, quarantine)
      displaced = identity(quarantine)
      unless same_identity?(displaced, expected_identity)
        restore_racer!(quarantine, name, displaced)
        raise RaceLost, "Secure remove lost a destination race"
      end

      unlink_random_owned!(quarantine, expected_identity)
      true
    end

    private

    def rename_exclusive!(source, destination)
      validate_name!(source)
      validate_name!(destination)
      result = Darwin.renameatx_np(
        @io.fileno,
        source,
        @io.fileno,
        destination,
        SECURE_RENAME_FLAGS
      )
      raise_system_call!("renameatx_np") unless result.zero?
    end

    def restore_racer!(quarantine, final_name, displaced, kind: :file)
      rename_exclusive!(quarantine, final_name)
      restored = kind == :directory ? directory_identity(final_name) : identity(final_name)
      unless same_identity?(restored, displaced)
        raise RaceLost, "Displaced racer could not be verified after restoration"
      end
    rescue Error
      raise RaceLost, "Displaced racer was preserved in quarantine"
    end

    def unlink_random_owned!(name, expected_identity, directory: false)
      current = directory ? directory_identity(name) : identity(name)
      unless same_identity?(current, expected_identity)
        raise RaceLost, "Random quarantine inode changed before cleanup"
      end

      flags = directory ? 0x80 : 0
      result = Darwin.unlinkat(@io.fileno, name, flags)
      raise_system_call!("unlinkat") unless result.zero?
    end

    def same_identity?(actual, expected)
      actual.device == expected.device && actual.inode == expected.inode && actual.owner == expected.owner
    end

    def quarantine_name
      ".immich-quarantine-#{SecureRandom.hex(16)}"
    end

    def validate_name!(name)
      unless name.is_a?(String) && !name.empty? && name != "." && name != ".." && File.basename(name) == name
        raise Error, "Secure file operation requires a basename"
      end
    end

    def raise_system_call!(operation)
      raise Error, "#{operation} failed with errno #{FFI.errno}"
    end
  end
end

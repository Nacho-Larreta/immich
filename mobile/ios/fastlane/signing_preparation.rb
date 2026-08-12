# frozen_string_literal: true

require "digest"
require "openssl"
require "base64"
require "cfpropertylist"
require "pathname"
require "stringio"
require "tempfile"
require_relative "secure_file_operations"

module SigningPreparation
  class InvalidPlan < ArgumentError; end

  Profile = Struct.new(:target, :bundle_id_suffix, :path, keyword_init: true) do
    def initialize(**values)
      super
      freeze
    end
  end

  class Plan
    CERTIFICATE_ID = /\A[A-Za-z0-9_-]+\z/
    IMPORT_REQUIREMENTS = %w[
      SIGNING_P12_PATH
      SIGNING_P12_PASSWORD
      SIGNING_CERTIFICATE_SHA256
      SIGNING_CERTIFICATE_ID
    ].freeze
    PROFILE_REQUIREMENTS = %w[
      DEVELOPER_PORTAL_TEAM_ID
      RUNNER_PROFILE_PATH
      SHARE_EXTENSION_PROFILE_PATH
      WIDGET_EXTENSION_PROFILE_PATH
    ].freeze
    MODES = %w[import create_authorized].freeze

    attr_reader :mode,
                :p12_path,
                :p12_password,
                :certificate_sha256,
                :certificate_id,
                :profiles,
                :backup_directory,
                :developer_portal_team_id

    def self.from_env(env, api_key_configuration:)
      mode = required(env, "SIGNING_PREPARATION_MODE")
      raise InvalidPlan, "SIGNING_PREPARATION_MODE must be import or create_authorized" unless MODES.include?(mode)

      raise InvalidPlan, "Signing preparation requires a team API key" unless api_key_configuration.team?

      requirements = PROFILE_REQUIREMENTS + (mode == "import" ? IMPORT_REQUIREMENTS : ["SIGNING_P12_PASSWORD"])
      values = requirements.each_with_object({}) do |name, result|
        result[name] = required(env, name)
      end
      fingerprint = values["SIGNING_CERTIFICATE_SHA256"]
      if fingerprint && !fingerprint.match?(/\A[0-9a-f]{64}\z/i)
        raise InvalidPlan, "SIGNING_CERTIFICATE_SHA256 must be a SHA-256 fingerprint"
      end
      certificate_id = values["SIGNING_CERTIFICATE_ID"]
      if certificate_id && !certificate_id.match?(CERTIFICATE_ID)
        raise InvalidPlan, "SIGNING_CERTIFICATE_ID contains invalid characters"
      end

      backup_directory = nil
      if mode == "create_authorized"
        unless env["SIGNING_CREATE_AUTHORIZED"] == "true"
          raise InvalidPlan, "SIGNING_CREATE_AUTHORIZED must be true for create_authorized"
        end
        backup_directory = verified_backup_directory(required(env, "SIGNING_BACKUP_DIRECTORY"))
      end

      new(
        mode: mode.to_sym,
        p12_path: values["SIGNING_P12_PATH"],
        p12_password: values["SIGNING_P12_PASSWORD"],
        certificate_sha256: fingerprint&.downcase,
        certificate_id: certificate_id,
        profiles: profiles(values),
        backup_directory: backup_directory,
        developer_portal_team_id: values.fetch("DEVELOPER_PORTAL_TEAM_ID")
      )
    end

    def initialize(mode:, p12_path:, p12_password:, certificate_sha256:, certificate_id:, profiles:, backup_directory:, developer_portal_team_id:)
      @mode = mode
      @p12_path = p12_path&.freeze
      @p12_password = p12_password&.freeze
      @certificate_sha256 = certificate_sha256&.freeze
      @certificate_id = certificate_id&.freeze
      @profiles = profiles.freeze
      @backup_directory = backup_directory&.freeze
      @developer_portal_team_id = developer_portal_team_id.freeze
      freeze
    end

    def inspect
      "#<#{self.class.name} mode=#{mode} profile_count=#{profiles.length}>"
    end

    class << self
      private

      def required(env, name)
        value = env[name]
        raise InvalidPlan, "#{name} must be set explicitly" unless value.is_a?(String) && !value.strip.empty?

        value.strip
      end

      def profiles(values)
        [
          Profile.new(target: "Runner", bundle_id_suffix: "", path: values.fetch("RUNNER_PROFILE_PATH")),
          Profile.new(target: "ShareExtension", bundle_id_suffix: ".ShareExtension", path: values.fetch("SHARE_EXTENSION_PROFILE_PATH")),
          Profile.new(target: "WidgetExtension", bundle_id_suffix: ".WidgetExtension", path: values.fetch("WIDGET_EXTENSION_PROFILE_PATH"))
        ].freeze
      end

      def verified_backup_directory(path)
        expanded = Pathname.new(path).expand_path
        stat = File.lstat(expanded)
        unless stat.directory? && !stat.symlink?
          raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY must be a real directory, not a symlink"
        end
        unless stat.uid == Process.euid
          raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY must be owned by the current user"
        end
        unless stat.mode & 0o777 == 0o700
          raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY permissions must be 0700"
        end

        resolved = expanded.realpath
        repository_root = Pathname.new(File.expand_path("../../..", __dir__)).realpath
        if resolved == repository_root || resolved.to_s.start_with?("#{repository_root}#{File::SEPARATOR}")
          raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY must be outside the Git repository"
        end
        unless Dir.children(resolved).empty?
          raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY must be an empty dedicated directory"
        end

        resolved.to_s
      rescue Errno::ENOENT, Errno::EACCES
        raise InvalidPlan, "SIGNING_BACKUP_DIRECTORY must be an accessible existing directory"
      end
    end
  end

  class PartialState
    attr_reader :certificate_imported, :certificate_created, :profiles_ready

    def initialize
      @certificate_imported = false
      @certificate_created = false
      @profiles_ready = 0
    end

    def certificate_imported!
      @certificate_imported = true
    end

    def certificate_created!
      @certificate_created = true
    end

    def profile_ready!
      @profiles_ready += 1
    end

    def evidence
      {
        certificate_imported: certificate_imported,
        certificate_created: certificate_created,
        profiles_ready: profiles_ready,
        complete: (certificate_imported || certificate_created) && profiles_ready == 3
      }.freeze
    end
  end

  FileIdentity = SecureFileOperations::Identity

  module RegularFile
    module_function

    def read_owned!(path, description:)
      before = owned_identity!(path, description: description)
      io = File.open(path, File::RDONLY | File::NOFOLLOW)
      after_open = identity(io.stat)
      unless before == after_open
        raise InvalidPlan, "#{description} changed while it was opened"
      end

      [io.binmode.read, before]
    rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
      raise InvalidPlan, "#{description} must be an accessible regular file"
    ensure
      io&.close
    end

    def verify_unchanged!(path, expected_identity, description:)
      unless owned_identity!(path, description: description) == expected_identity
        raise InvalidPlan, "#{description} changed unexpectedly"
      end

      true
    end

    def owned_identity!(path, description:)
      stat = File.lstat(path)
      unless stat.file? && !stat.symlink? && stat.nlink == 1
        raise InvalidPlan, "#{description} must be a regular non-symlink file"
      end
      unless stat.uid == Process.euid
        raise InvalidPlan, "#{description} must be owned by the current user"
      end

      identity(stat)
    rescue Errno::ENOENT, Errno::EACCES
      raise InvalidPlan, "#{description} must be an accessible regular file"
    end

    def identity(stat)
      FileIdentity.new(device: stat.dev, inode: stat.ino, owner: stat.uid)
    end
    private_class_method :identity
  end

  Identity = Struct.new(:certificate, :private_key, :fingerprint, keyword_init: true) do
    def initialize(**values)
      super
      freeze
    end

    def inspect
      "#<#{self.class.name} fingerprint=redacted>"
    end
  end

  module IdentityVerifier
    module_function

    def verify_pkcs12!(p12_path:, password:, expected_fingerprint: nil)
      content, = RegularFile.read_owned!(p12_path, description: "SIGNING_P12_PATH")
      p12 = OpenSSL::PKCS12.new(content, password)
      certificate = p12.certificate
      private_key = p12.key
      unless certificate.is_a?(OpenSSL::X509::Certificate) && private_key.is_a?(OpenSSL::PKey::PKey)
        raise InvalidPlan, "SIGNING_P12_PATH must contain a certificate and private key"
      end
      unless certificate.public_key.to_der == private_key.public_key.to_der
        raise InvalidPlan, "Signing certificate and private key do not match"
      end

      fingerprint = Digest::SHA256.hexdigest(certificate.to_der)
      if expected_fingerprint && fingerprint != expected_fingerprint
        raise InvalidPlan, "Signing certificate fingerprint does not match"
      end

      Identity.new(certificate: certificate, private_key: private_key, fingerprint: fingerprint)
    rescue Errno::ENOENT, Errno::EACCES, OpenSSL::PKCS12::PKCS12Error, OpenSSL::PKey::PKeyError
      raise InvalidPlan, "SIGNING_P12_PATH must contain the expected readable PKCS#12 identity"
    end
  end

  module PortalCertificateVerifier
    module_function

    def verify!(portal_certificate:, expected_id:, expected_fingerprint:)
      unless portal_certificate && portal_certificate.respond_to?(:id) && portal_certificate.id.to_s == expected_id
        raise InvalidPlan, "SIGNING_CERTIFICATE_ID did not resolve exactly"
      end

      encoded = portal_certificate.respond_to?(:certificate_content) ? portal_certificate.certificate_content : nil
      certificate = OpenSSL::X509::Certificate.new(Base64.strict_decode64(encoded.to_s))
      unless Digest::SHA256.hexdigest(certificate.to_der) == expected_fingerprint
        raise InvalidPlan, "SIGNING_CERTIFICATE_ID does not match the expected certificate fingerprint"
      end

      true
    rescue ArgumentError, OpenSSL::X509::CertificateError
      raise InvalidPlan, "SIGNING_CERTIFICATE_ID returned an invalid certificate"
    end
  end

  module EncryptedBackup
    module_function

    PRIVATE_KEY_PEM = /-----BEGIN (?:RSA |EC )?PRIVATE KEY-----/.freeze

    def secure_created_identity!(directory:, certificate_id:, password:, before_replace: nil)
      unless certificate_id.is_a?(String) && certificate_id.match?(Plan::CERTIFICATE_ID)
        raise InvalidPlan, "Created certificate ID contains invalid characters"
      end

      certificate_path = File.join(directory, "#{certificate_id}.cer")
      private_key_path = File.join(directory, "#{certificate_id}.p12")
      request_path = File.join(directory, "#{certificate_id}.certSigningRequest")
      certificate_content, = RegularFile.read_owned!(certificate_path, description: "Created certificate")
      RegularFile.read_owned!(request_path, description: "Created certificate request")
      private_key_content, private_identity = RegularFile.read_owned!(
        private_key_path,
        description: "Created private key"
      )
      cleanup_identity = private_identity
      certificate = OpenSSL::X509::Certificate.new(certificate_content)
      private_key = OpenSSL::PKey.read(private_key_content)
      unless certificate.public_key.to_der == private_key.public_key.to_der
        raise InvalidPlan, "Created signing certificate and private key do not match"
      end

      encrypted = OpenSSL::PKCS12.create(password, "Apple Distribution", private_key, certificate).to_der
      cleanup_identity = replace_with_private_file!(
        private_key_path,
        encrypted,
        expected_identity: private_identity,
        before_replace: before_replace
      )
      verify_encryption!(private_key_path, password)
      identity = IdentityVerifier.verify_pkcs12!(p12_path: private_key_path, password: password)
      RegularFile.verify_unchanged!(private_key_path, cleanup_identity, description: "Encrypted signing backup")
      identity
    rescue InvalidPlan, SecureFileOperations::Error, Errno::ENOENT, Errno::EACCES,
           OpenSSL::X509::CertificateError, OpenSSL::PKey::PKeyError => error
      remove_owned_file(private_key_path, cleanup_identity)
      raise error if error.is_a?(InvalidPlan)

      raise InvalidPlan, "Created signing backup could not be verified: #{error.class.name.split('::').last}"
    end

    def remove_plaintext_private_keys!(directory:, before_remove: nil)
      Dir.children(directory).grep(/\.p12\z/).each do |name|
        path = File.join(directory, name)
        content, identity = RegularFile.read_owned!(path, description: "Incomplete signing backup")
        remove_owned_file(path, identity, before_remove: before_remove) if content.match?(PRIVATE_KEY_PEM)
        before_remove = nil
      rescue InvalidPlan
        next
      end
    rescue Errno::ENOENT, Errno::EACCES
      nil
    end

    def replace_with_private_file!(path, content, expected_identity:, before_replace:)
      directory = File.dirname(path)
      published_identity = nil
      Tempfile.create(["signing-identity", ".p12"], File.dirname(path), mode: File::RDWR | File::CREAT, perm: 0o600) do |file|
        file.binmode
        file.write(content)
        file.flush
        file.fsync
        staging_identity = RegularFile.owned_identity!(file.path, description: "Encrypted signing staging file")
        operations = SecureFileOperations::Directory.new(directory)
        begin
          published_identity = operations.replace_owned!(
            final_name: File.basename(path),
            staging_name: File.basename(file.path),
            expected_final: expected_identity,
            expected_staging: staging_identity,
            before_operation: before_replace
          )
        ensure
          operations.close
        end
      end
      published_identity
    end
    private_class_method :replace_with_private_file!

    def verify_encryption!(path, password)
      begin
        content, = RegularFile.read_owned!(path, description: "Encrypted signing backup")
        OpenSSL::PKCS12.new(content, "")
      rescue OpenSSL::PKCS12::PKCS12Error
        return true
      end
      raise InvalidPlan, "Created signing backup is not encrypted"
    ensure
      IdentityVerifier.verify_pkcs12!(p12_path: path, password: password)
    end
    private_class_method :verify_encryption!

    def remove_owned_file(path, expected_identity, before_remove: nil)
      return unless path && expected_identity

      operations = SecureFileOperations::Directory.new(File.dirname(path))
      operations.remove_owned!(
        name: File.basename(path),
        expected_identity: expected_identity,
        before_operation: before_remove
      )
    rescue InvalidPlan, SecureFileOperations::Error, Errno::ENOENT, Errno::EACCES
      nil
    ensure
      operations&.close
    end
    private_class_method :remove_owned_file
  end

  module ProfileVerifier
    module_function

    MAX_CERTIFICATE_DER_BYTES = 64 * 1024

    def verify_destination!(path)
      parent = File.dirname(path)
      stat = File.lstat(parent)
      unless stat.directory? && !stat.symlink? && stat.uid == Process.euid && stat.mode & 0o077 == 0
        raise InvalidPlan, "Provisioning profile directory must be private and owned by the current user"
      end
      if File.exist?(path) || File.symlink?(path)
        RegularFile.owned_identity!(path, description: "Provisioning profile")
      end
      true
    rescue Errno::ENOENT, Errno::EACCES
      raise InvalidPlan, "Provisioning profile directory must already exist"
    end

    def verify_file!(path:, expected_bundle_id:, certificate_sha256:)
      identity = RegularFile.owned_identity!(path, description: "Provisioning profile")
      profile_data = yield(path)
      RegularFile.verify_unchanged!(path, identity, description: "Provisioning profile")
      verify!(
        profile_data: profile_data,
        expected_bundle_id: expected_bundle_id,
        certificate_sha256: certificate_sha256
      )
    end

    def verify!(profile_data:, expected_bundle_id:, certificate_sha256:)
      entitlements = profile_data["Entitlements"] || {}
      application_identifier = entitlements["application-identifier"].to_s
      unless application_identifier.end_with?(".#{expected_bundle_id}")
        raise InvalidPlan, "Provisioning profile does not match its exact bundle ID"
      end

      fingerprints = Array(profile_data["DeveloperCertificates"]).map do |certificate|
        certificate_fingerprint!(certificate)
      end
      unless fingerprints.include?(certificate_sha256)
        raise InvalidPlan, "Provisioning profile does not contain the expected signing certificate"
      end

      true
    end

    def certificate_fingerprint!(certificate)
      der = if certificate.instance_of?(CFPropertyList::Blob)
              String.new(certificate)
            else
              case certificate
              when OpenSSL::X509::Certificate
                certificate.to_der
              when StringIO, IO
                read_certificate_stream!(certificate)
              else
                raise InvalidPlan, "Provisioning profile contains an invalid signing certificate"
              end
            end
      unless der.is_a?(String) && !der.empty? && der.bytesize <= MAX_CERTIFICATE_DER_BYTES
        raise InvalidPlan, "Provisioning profile contains an invalid signing certificate"
      end

      parsed_certificate = OpenSSL::X509::Certificate.new(der)
      Digest::SHA256.hexdigest(parsed_certificate.to_der)
    rescue IOError, SystemCallError, TypeError, OpenSSL::X509::CertificateError
      raise InvalidPlan, "Provisioning profile contains an invalid signing certificate"
    end
    private_class_method :certificate_fingerprint!

    def read_certificate_stream!(stream)
      original_position = stream.pos
      stream.rewind
      stream.read(MAX_CERTIFICATE_DER_BYTES + 1)
    ensure
      stream.seek(original_position, IO::SEEK_SET) if original_position
    end
    private_class_method :read_certificate_stream!
  end
end

# frozen_string_literal: true

require "openssl"

module InstalledSigningIdentity
  class VerificationError < StandardError; end
  class MalformedOutput < StandardError; end

  Certificate = Struct.new(:sha1, :sha256, keyword_init: true) do
    def initialize(**values)
      super(**values.transform_values { |value| value.dup.freeze })
      freeze
    end

    def inspect
      "#<#{self.class.name || 'InstalledSigningIdentity::Certificate'} redacted>"
    end
  end

  VerificationResult = Struct.new(:keychain_name, :certificate_sha1, :certificate_sha256, keyword_init: true) do
    def initialize(**values)
      super(**values.transform_values { |value| value.dup.freeze })
      freeze
    end

    def inspect
      "#<#{self.class.name || 'InstalledSigningIdentity::VerificationResult'} verified=true redacted>"
    end
  end

  class Parser
    MAX_OUTPUT_BYTES = 1024 * 1024
    CERTIFICATE_PEM = /-----BEGIN CERTIFICATE-----\s+.+?\s+-----END CERTIFICATE-----/m
    IDENTITY = /\A([1-9][0-9]*)\) ([0-9a-fA-F]{40}) ".*"\z/
    SUMMARY = /\A(0|[1-9][0-9]*) valid identities found\z/

    def certificates(output)
      text = validated_output(output)
      return [].freeze if text.strip.empty?

      pem_blocks = text.scan(CERTIFICATE_PEM)
      unless !pem_blocks.empty? && text.gsub(CERTIFICATE_PEM, "").strip.empty?
        raise MalformedOutput, "Certificate command returned malformed output"
      end

      pem_blocks.map do |pem|
        certificate = OpenSSL::X509::Certificate.new(pem)
        Certificate.new(
          sha1: OpenSSL::Digest::SHA1.hexdigest(certificate.to_der),
          sha256: OpenSSL::Digest::SHA256.hexdigest(certificate.to_der)
        )
      end.freeze
    rescue OpenSSL::X509::CertificateError
      raise MalformedOutput, "Certificate command returned malformed output"
    end

    def codesigning_identities(output)
      lines = validated_output(output).lines.map(&:strip).reject(&:empty?)
      raise MalformedOutput, "Identity command returned malformed output" if lines.empty?

      summary = SUMMARY.match(lines.pop)
      raise MalformedOutput, "Identity command returned malformed output" unless summary

      identities = lines.each_with_index.map do |line, index|
        match = IDENTITY.match(line)
        unless match && match[1].to_i == index + 1
          raise MalformedOutput, "Identity command returned malformed output"
        end

        match[2].downcase.freeze
      end
      unless summary[1].to_i == identities.length
        raise MalformedOutput, "Identity command returned malformed output"
      end

      identities.freeze
    end

    private

    def validated_output(output)
      unless output.is_a?(String) && output.bytesize <= MAX_OUTPUT_BYTES && output.valid_encoding?
        raise MalformedOutput, "Keychain command returned malformed output"
      end

      output
    end
  end

  class Verifier
    SECURITY = "/usr/bin/security"
    CERTIFICATE_COMMAND = [SECURITY, "find-certificate", "-a", "-p"].map(&:freeze).freeze
    IDENTITY_COMMAND = [SECURITY, "find-identity", "-v", "-p", "codesigning"].map(&:freeze).freeze
    KEYCHAIN_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/
    SHA1 = /\A[0-9a-f]{40}\z/
    SHA256 = /\A[0-9a-f]{64}\z/

    def initialize(argv_runner:, parser:)
      @argv_runner = argv_runner
      @parser = parser
    end

    def verify!(keychain_name:, expected_sha256:)
      validated_keychain = validate_keychain_name(keychain_name)
      validated_sha256 = validate_sha256(expected_sha256)

      certificates = parse_certificates(run(CERTIFICATE_COMMAND, validated_keychain))
      matching_certificates = certificates.select { |certificate| certificate.sha256 == validated_sha256 }
      unless matching_certificates.length == 1
        raise VerificationError, "Expected exactly one installed certificate with the configured fingerprint"
      end

      identities = parse_identities(run(IDENTITY_COMMAND, validated_keychain))
      matching_identities = identities.count { |sha1| sha1 == matching_certificates.first.sha1 }
      unless matching_identities == 1
        raise VerificationError, "Expected exactly one codesigning identity with its private key"
      end

      VerificationResult.new(
        keychain_name: validated_keychain,
        certificate_sha1: matching_certificates.first.sha1,
        certificate_sha256: validated_sha256
      )
    end

    def inspect
      "#<#{self.class.name} redacted>"
    end

    private

    def validate_keychain_name(keychain_name)
      unless keychain_name.is_a?(String) && keychain_name.match?(KEYCHAIN_NAME)
        raise VerificationError, "KEYCHAIN_NAME must be an explicit unambiguous keychain name"
      end

      keychain_name.dup.freeze
    end

    def validate_sha256(fingerprint)
      unless fingerprint.is_a?(String) && fingerprint.match?(SHA256)
        raise VerificationError, "SIGNING_CERTIFICATE_SHA256 must be exactly 64 lowercase hexadecimal characters"
      end

      fingerprint.dup.freeze
    end

    def run(command, keychain_name)
      argv = (command + [keychain_name]).map { |argument| argument.dup.freeze }.freeze
      result = @argv_runner.call(argv)
      unless result.respond_to?(:stdout) && result.respond_to?(:stderr) && result.respond_to?(:exit_status) &&
             result.stdout.is_a?(String) && result.stderr.is_a?(String) && result.exit_status == 0
        raise VerificationError, "Keychain inspection command failed"
      end

      result.stdout
    rescue VerificationError
      raise
    rescue StandardError
      raise VerificationError, "Keychain inspection command failed"
    end

    def parse_certificates(output)
      certificates = @parser.certificates(output)
      unless certificates.is_a?(Array) && certificates.all? { |certificate| valid_certificate?(certificate) }
        raise VerificationError, "Certificate parser returned malformed output"
      end

      certificates
    rescue MalformedOutput
      raise VerificationError, "Certificate parser rejected malformed output"
    rescue VerificationError
      raise
    rescue StandardError
      raise VerificationError, "Certificate parser failed"
    end

    def parse_identities(output)
      identities = @parser.codesigning_identities(output)
      unless identities.is_a?(Array) && identities.all? { |sha1| sha1.is_a?(String) && sha1.match?(SHA1) }
        raise VerificationError, "Identity parser returned malformed output"
      end

      identities
    rescue MalformedOutput
      raise VerificationError, "Identity parser rejected malformed output"
    rescue VerificationError
      raise
    rescue StandardError
      raise VerificationError, "Identity parser failed"
    end

    def valid_certificate?(certificate)
      certificate.respond_to?(:sha1) && certificate.respond_to?(:sha256) &&
        certificate.sha1.is_a?(String) && certificate.sha1.match?(SHA1) &&
        certificate.sha256.is_a?(String) && certificate.sha256.match?(SHA256)
    end
  end
end

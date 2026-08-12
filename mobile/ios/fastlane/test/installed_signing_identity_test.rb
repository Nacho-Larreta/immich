# frozen_string_literal: true

require "minitest/autorun"
require "openssl"
require_relative "../installed_signing_identity"

class InstalledSigningIdentityTest < Minitest::Test
  CommandResult = Struct.new(:stdout, :stderr, :exit_status, keyword_init: true)

  class FakeArgvRunner
    attr_reader :calls

    def initialize(results = [], error: nil)
      @results = results.dup
      @error = error
      @calls = []
    end

    def call(argv)
      @calls << argv
      raise @error if @error

      @results.shift
    end
  end

  def setup
    @certificate = self_signed_certificate("expected")
    @fingerprint = OpenSSL::Digest::SHA256.hexdigest(@certificate.to_der)
    @sha1 = OpenSSL::Digest::SHA1.hexdigest(@certificate.to_der)
    @keychain_name = "nachofotos-build.keychain-db"
  end

  def test_matches_the_exact_certificate_to_one_codesigning_identity_with_private_key
    runner = runner_for(
      certificate_output: @certificate.to_pem,
      identity_output: identity_output(@sha1)
    )

    result = verifier(runner).verify!(
      keychain_name: @keychain_name,
      expected_sha256: @fingerprint
    )

    assert_equal @fingerprint, result.certificate_sha256
    assert_equal @sha1, result.certificate_sha1
    assert_equal @keychain_name, result.keychain_name
    assert result.frozen?
    assert result.keychain_name.frozen?
    assert result.certificate_sha256.frozen?
    assert result.certificate_sha1.frozen?
    refute_includes result.inspect, @keychain_name
    refute_includes result.inspect, @fingerprint
    refute_includes result.inspect, @sha1
    assert_equal(
      [
        ["/usr/bin/security", "find-certificate", "-a", "-p", @keychain_name],
        ["/usr/bin/security", "find-identity", "-v", "-p", "codesigning", @keychain_name]
      ],
      runner.calls
    )
    assert runner.calls.all?(&:frozen?)
    assert runner.calls.flatten.all?(&:frozen?)
    refute_respond_to verifier(runner), :verify_pkcs12!
  end

  def test_rejects_an_absent_expected_certificate
    another_certificate = self_signed_certificate("another")
    runner = runner_for(
      certificate_output: another_certificate.to_pem,
      identity_output: identity_output(OpenSSL::Digest::SHA1.hexdigest(another_certificate.to_der))
    )

    error = assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(runner).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
    end

    assert_includes error.message, "exactly one"
    refute_includes error.message, @fingerprint
    assert_equal 1, runner.calls.length
  end

  def test_rejects_a_certificate_without_its_private_key_codesigning_identity
    runner = runner_for(
      certificate_output: @certificate.to_pem,
      identity_output: "     0 valid identities found\n"
    )

    error = assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(runner).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
    end

    assert_includes error.message, "private key"
    refute_includes error.message, @sha1
  end

  def test_rejects_multiple_matching_certificates_or_codesigning_identities
    duplicate_certificate_runner = runner_for(
      certificate_output: @certificate.to_pem + @certificate.to_pem,
      identity_output: identity_output(@sha1)
    )
    assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(duplicate_certificate_runner).verify!(
        keychain_name: @keychain_name,
        expected_sha256: @fingerprint
      )
    end

    duplicate_identity_runner = runner_for(
      certificate_output: @certificate.to_pem,
      identity_output: identity_output(@sha1, @sha1)
    )
    assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(duplicate_identity_runner).verify!(
        keychain_name: @keychain_name,
        expected_sha256: @fingerprint
      )
    end
  end

  def test_rejects_malformed_certificate_and_identity_output
    malformed_outputs = [
      ["private malformed certificate output", identity_output(@sha1)],
      [@certificate.to_pem, "private malformed identity output"]
    ]

    malformed_outputs.each do |certificate_output, identity_output_value|
      error = assert_raises(InstalledSigningIdentity::VerificationError) do
        verifier(
          runner_for(
            certificate_output: certificate_output,
            identity_output: identity_output_value
          )
        ).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
      end

      refute_includes error.message, "private malformed"
    end
  end

  def test_fails_closed_on_runner_failure_without_echoing_stderr_or_exceptions
    failed_runner = FakeArgvRunner.new(
      [CommandResult.new(stdout: "", stderr: "private runner stderr", exit_status: 1)]
    )
    error = assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(failed_runner).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
    end
    refute_includes error.message, "private runner stderr"

    raising_runner = FakeArgvRunner.new(error: RuntimeError.new("private runner exception"))
    error = assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(raising_runner).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
    end
    refute_includes error.message, "private runner exception"
  end

  def test_requires_strict_keychain_and_canonical_lowercase_sha256_inputs
    [nil, "", " keychain", "keychain ", "-keychain", "path/keychain", "key;chain", "key\nchain"].each do |keychain_name|
      runner = runner_for(certificate_output: @certificate.to_pem, identity_output: identity_output(@sha1))
      assert_raises(InstalledSigningIdentity::VerificationError) do
        verifier(runner).verify!(keychain_name: keychain_name, expected_sha256: @fingerprint)
      end
      assert_empty runner.calls
    end

    [nil, "", "A" * 64, "a" * 63, "g" * 64, " #{@fingerprint}"].each do |fingerprint|
      runner = runner_for(certificate_output: @certificate.to_pem, identity_output: identity_output(@sha1))
      assert_raises(InstalledSigningIdentity::VerificationError) do
        verifier(runner).verify!(keychain_name: @keychain_name, expected_sha256: fingerprint)
      end
      assert_empty runner.calls
    end
  end

  def test_rejects_a_malformed_runner_result
    runner = FakeArgvRunner.new([Object.new])

    assert_raises(InstalledSigningIdentity::VerificationError) do
      verifier(runner).verify!(keychain_name: @keychain_name, expected_sha256: @fingerprint)
    end
  end

  private

  def verifier(runner)
    InstalledSigningIdentity::Verifier.new(
      argv_runner: runner,
      parser: InstalledSigningIdentity::Parser.new
    )
  end

  def runner_for(certificate_output:, identity_output:)
    FakeArgvRunner.new(
      [
        CommandResult.new(stdout: certificate_output, stderr: "", exit_status: 0),
        CommandResult.new(stdout: identity_output, stderr: "", exit_status: 0)
      ]
    )
  end

  def identity_output(*sha1_fingerprints)
    lines = sha1_fingerprints.each_with_index.map do |sha1, index|
      "  #{index + 1}) #{sha1.upcase} \"Apple Distribution: Redacted\""
    end
    (lines + ["     #{sha1_fingerprints.length} valid identities found"]).join("\n") + "\n"
  end

  def self_signed_certificate(common_name)
    key = OpenSSL::PKey::RSA.new(1024)
    name = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    certificate = OpenSSL::X509::Certificate.new
    certificate.version = 2
    certificate.serial = rand(1..100_000)
    certificate.subject = name
    certificate.issuer = name
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    certificate
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require "stringio"
require "tmpdir"
require_relative "../signing_preparation"

class SigningPreparationTest < Minitest::Test
  TEAM_KEY = Struct.new(:team?).new(true)
  INDIVIDUAL_KEY = Struct.new(:team?).new(false)
  IMPORT_ENV = {
    "DEVELOPER_PORTAL_TEAM_ID" => "developer-team",
    "SIGNING_PREPARATION_MODE" => "import",
    "SIGNING_P12_PATH" => "/secure/distribution.p12",
    "SIGNING_P12_PASSWORD" => "password-from-runtime",
    "SIGNING_CERTIFICATE_SHA256" => "a" * 64,
    "SIGNING_CERTIFICATE_ID" => "portal-certificate-id",
    "RUNNER_PROFILE_PATH" => "/secure/runner.mobileprovision",
    "SHARE_EXTENSION_PROFILE_PATH" => "/secure/share.mobileprovision",
    "WIDGET_EXTENSION_PROFILE_PATH" => "/secure/widget.mobileprovision"
  }.freeze

  def test_import_plan_requires_p12_fingerprint_certificate_id_and_exact_three_profiles
    plan = SigningPreparation::Plan.from_env(IMPORT_ENV, api_key_configuration: TEAM_KEY)

    assert_equal :import, plan.mode
    assert_equal 3, plan.profiles.length
    assert_equal %w[Runner ShareExtension WidgetExtension], plan.profiles.map(&:target)
    assert plan.frozen?
    refute_includes plan.inspect, "password-from-runtime"
    refute_includes plan.inspect, "/secure/distribution.p12"
  end

  def test_import_requires_team_key
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::Plan.from_env(IMPORT_ENV, api_key_configuration: INDIVIDUAL_KEY)
    end
  end

  def test_import_rejects_unsafe_certificate_id
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::Plan.from_env(
        IMPORT_ENV.merge("SIGNING_CERTIFICATE_ID" => "../certificate"),
        api_key_configuration: TEAM_KEY
      )
    end
  end

  def test_create_requires_explicit_authorization_and_team_key
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::Plan.from_env(
        IMPORT_ENV.merge("SIGNING_PREPARATION_MODE" => "create_authorized"),
        api_key_configuration: INDIVIDUAL_KEY
      )
    end
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::Plan.from_env(
        IMPORT_ENV.merge("SIGNING_PREPARATION_MODE" => "create_authorized"),
        api_key_configuration: TEAM_KEY
      )
    end

    Dir.mktmpdir do |directory|
      plan = SigningPreparation::Plan.from_env(
        IMPORT_ENV.reject { |name, _| name == "SIGNING_P12_PATH" || name.start_with?("SIGNING_CERTIFICATE") }.merge(
          "SIGNING_PREPARATION_MODE" => "create_authorized",
          "SIGNING_CREATE_AUTHORIZED" => "true",
          "SIGNING_BACKUP_DIRECTORY" => directory
        ),
        api_key_configuration: TEAM_KEY
      )
      assert_equal :create_authorized, plan.mode
      assert_equal File.realpath(directory), plan.backup_directory
    end
  end


  def test_create_rejects_backup_inside_repository
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::Plan.from_env(
        IMPORT_ENV.reject { |name, _| name == "SIGNING_P12_PATH" || name.start_with?("SIGNING_CERTIFICATE") }.merge(
          "SIGNING_PREPARATION_MODE" => "create_authorized",
          "SIGNING_CREATE_AUTHORIZED" => "true",
          "SIGNING_BACKUP_DIRECTORY" => File.expand_path("../..", __dir__)
        ),
        api_key_configuration: TEAM_KEY
      )
    end
  end

  def test_create_requires_owned_0700_non_symlink_empty_backup_directory
    Dir.mktmpdir do |parent|
      insecure = File.join(parent, "insecure")
      target = File.join(parent, "target")
      symlink = File.join(parent, "symlink")
      Dir.mkdir(insecure, 0o750)
      Dir.mkdir(target, 0o700)
      File.symlink(target, symlink)

      [insecure, symlink].each do |directory|
        assert_raises(SigningPreparation::InvalidPlan) { create_plan(directory) }
      end

      Process.stub(:euid, Process.euid + 1) do
        assert_raises(SigningPreparation::InvalidPlan) { create_plan(target) }
      end

      File.write(File.join(target, "unexpected"), "content")
      assert_raises(SigningPreparation::InvalidPlan) { create_plan(target) }
    end
  end

  def test_plan_has_no_revoke_or_delete_operation
    plan = SigningPreparation::Plan.from_env(IMPORT_ENV, api_key_configuration: TEAM_KEY)

    refute_respond_to plan, :revoke
    refute_respond_to plan, :delete
  end

  def test_profile_verifier_requires_exact_bundle_id_and_imported_certificate
    certificate, = self_signed_identity("profile")
    fingerprint = Digest::SHA256.hexdigest(certificate.to_der)
    profile = {
      "Entitlements" => { "application-identifier" => "portal-team.com.example.app" },
      "DeveloperCertificates" => [certificate]
    }

    assert SigningPreparation::ProfileVerifier.verify!(
      profile_data: profile,
      expected_bundle_id: "com.example.app",
      certificate_sha256: fingerprint
    )
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::ProfileVerifier.verify!(
        profile_data: profile,
        expected_bundle_id: "com.example.other",
        certificate_sha256: fingerprint
      )
    end
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::ProfileVerifier.verify!(
        profile_data: profile,
        expected_bundle_id: "com.example.app",
        certificate_sha256: "0" * 64
      )
    end
  end

  def test_profile_verifier_reads_fastlane_certificate_stream_without_consuming_it
    certificate, = self_signed_identity("fastlane-profile")
    certificate_stream = StringIO.new(certificate.to_der)
    original_position = certificate.to_der.bytesize / 2
    certificate_stream.pos = original_position

    assert SigningPreparation::ProfileVerifier.verify!(
      profile_data: profile_with_certificate(certificate_stream),
      expected_bundle_id: "com.example.app",
      certificate_sha256: Digest::SHA256.hexdigest(certificate.to_der)
    )
    assert_equal original_position, certificate_stream.pos
  end

  def test_profile_verifier_reads_io_certificate_without_consuming_it
    certificate, = self_signed_identity("io-profile")

    Dir.mktmpdir do |directory|
      path = File.join(directory, "certificate.cer")
      File.binwrite(path, certificate.to_der)
      File.open(path, "rb") do |certificate_stream|
        original_position = certificate.to_der.bytesize / 2
        certificate_stream.pos = original_position

        assert SigningPreparation::ProfileVerifier.verify!(
          profile_data: profile_with_certificate(certificate_stream),
          expected_bundle_id: "com.example.app",
          certificate_sha256: Digest::SHA256.hexdigest(certificate.to_der)
        )
        assert_equal original_position, certificate_stream.pos
      end
    end
  end

  def test_profile_verifier_rejects_unsupported_unreadable_and_malformed_certificates
    certificate, = self_signed_identity("invalid-profile")
    unsupported_certificate = Struct.new(:content) do
      def to_s
        content
      end
    end.new(certificate.to_der)
    closed_stream = StringIO.new(certificate.to_der)
    closed_stream.close

    [unsupported_certificate, closed_stream, StringIO.new("not-a-certificate")].each do |profile_certificate|
      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::ProfileVerifier.verify!(
          profile_data: profile_with_certificate(profile_certificate),
          expected_bundle_id: "com.example.app",
          certificate_sha256: Digest::SHA256.hexdigest(certificate.to_der)
        )
      end
    end
  end

  def test_profile_verifier_rejects_oversized_certificate_stream
    certificate, private_key = self_signed_identity("oversized-profile")
    certificate.add_extension(OpenSSL::X509::Extension.new("1.2.3.4", "a" * (64 * 1024)))
    certificate.sign(private_key, OpenSSL::Digest::SHA256.new)

    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::ProfileVerifier.verify!(
        profile_data: profile_with_certificate(StringIO.new(certificate.to_der)),
        expected_bundle_id: "com.example.app",
        certificate_sha256: Digest::SHA256.hexdigest(certificate.to_der)
      )
    end
  end

  def test_profile_file_verifier_rejects_symlinks_and_replacement
    certificate = "certificate-der"
    fingerprint = Digest::SHA256.hexdigest(certificate)
    profile = {
      "Entitlements" => { "application-identifier" => "portal-team.com.example.app" },
      "DeveloperCertificates" => [certificate]
    }

    Dir.mktmpdir do |directory|
      path = File.join(directory, "profile.mobileprovision")
      symlink = File.join(directory, "profile-link.mobileprovision")
      File.write(path, "profile")
      File.symlink(path, symlink)
      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::ProfileVerifier.verify_file!(
          path: symlink,
          expected_bundle_id: "com.example.app",
          certificate_sha256: fingerprint
        ) { profile }
      end

      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::ProfileVerifier.verify_file!(
          path: path,
          expected_bundle_id: "com.example.app",
          certificate_sha256: fingerprint
        ) do
          replacement = File.join(directory, "replacement")
          File.write(replacement, "replacement")
          File.rename(replacement, path)
          profile
        end
      end
    end
  end

  def test_profile_destination_requires_private_owned_directory_and_regular_file
    Dir.mktmpdir do |parent|
      secure = File.join(parent, "secure")
      insecure = File.join(parent, "insecure")
      Dir.mkdir(secure, 0o700)
      Dir.mkdir(insecure, 0o755)
      regular = File.join(secure, "regular.mobileprovision")
      symlink = File.join(secure, "symlink.mobileprovision")
      File.write(regular, "profile")
      File.symlink(regular, symlink)

      assert SigningPreparation::ProfileVerifier.verify_destination!(File.join(secure, "new.mobileprovision"))
      assert SigningPreparation::ProfileVerifier.verify_destination!(regular)
      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::ProfileVerifier.verify_destination!(symlink)
      end
      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::ProfileVerifier.verify_destination!(File.join(insecure, "new.mobileprovision"))
      end
    end
  end


  def test_identity_verifier_requires_private_key_certificate_match_and_exact_fingerprint
    certificate, private_key = self_signed_identity("expected")

    Dir.mktmpdir do |directory|
      matching_path = File.join(directory, "matching.p12")
      certificate_only_path = File.join(directory, "certificate-only.p12")
      File.binwrite(matching_path, OpenSSL::PKCS12.create("secret", "identity", private_key, certificate).to_der)
      File.binwrite(certificate_only_path, "not-used-by-stub")
      fingerprint = Digest::SHA256.hexdigest(certificate.to_der)

      identity = SigningPreparation::IdentityVerifier.verify_pkcs12!(
        p12_path: matching_path,
        password: "secret",
        expected_fingerprint: fingerprint
      )
      assert_equal fingerprint, identity.fingerprint
      certificate_without_key = Struct.new(:certificate, :key).new(certificate, nil)
      OpenSSL::PKCS12.stub(:new, certificate_without_key) do
        assert_raises(SigningPreparation::InvalidPlan) do
          SigningPreparation::IdentityVerifier.verify_pkcs12!(p12_path: certificate_only_path, password: "secret")
        end
      end
      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::IdentityVerifier.verify_pkcs12!(
          p12_path: matching_path,
          password: "secret",
          expected_fingerprint: "0" * 64
        )
      end
    end
  end

  def test_created_backup_rejects_certificate_and_private_key_mismatch
    certificate, = self_signed_identity("certificate")
    _, other_key = self_signed_identity("other-key")

    Dir.mktmpdir do |directory|
      write_created_outputs(directory, "created-id", certificate, other_key)

      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::EncryptedBackup.secure_created_identity!(
          directory: directory,
          certificate_id: "created-id",
          password: "backup-secret"
        )
      end
      refute File.exist?(File.join(directory, "created-id.p12"))
    end
  end

  def test_created_backup_rejects_symlink_output_without_deleting_target
    certificate, private_key = self_signed_identity("created")

    Dir.mktmpdir do |parent|
      directory = File.join(parent, "backup")
      Dir.mkdir(directory, 0o700)
      File.binwrite(File.join(directory, "created-id.cer"), certificate.to_der)
      File.write(File.join(directory, "created-id.certSigningRequest"), "request")
      target = File.join(parent, "private-key.pem")
      File.write(target, private_key.to_pem)
      File.symlink(target, File.join(directory, "created-id.p12"))

      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::EncryptedBackup.secure_created_identity!(
          directory: directory,
          certificate_id: "created-id",
          password: "backup-secret"
        )
      end
      assert File.file?(target)
      assert File.symlink?(File.join(directory, "created-id.p12"))
    end
  end

  def test_failed_cert_action_cleanup_removes_only_owned_plaintext_pem
    _, private_key = self_signed_identity("cleanup")

    Dir.mktmpdir do |parent|
      directory = File.join(parent, "backup")
      Dir.mkdir(directory, 0o700)
      owned = File.join(directory, "owned.p12")
      encrypted = File.join(directory, "encrypted.p12")
      external = File.join(parent, "external.p12")
      symlink = File.join(directory, "symlink.p12")
      File.write(owned, private_key.to_pem)
      File.binwrite(encrypted, "encrypted-container")
      File.write(external, private_key.to_pem)
      File.symlink(external, symlink)

      SigningPreparation::EncryptedBackup.remove_plaintext_private_keys!(directory: directory)

      refute File.exist?(owned)
      assert File.exist?(encrypted)
      assert File.exist?(external)
      assert File.symlink?(symlink)
    end
  end

  def test_encrypted_replace_preserves_racer_that_wins_just_before_move
    certificate, private_key = self_signed_identity("replace-race")

    Dir.mktmpdir do |directory|
      certificate_id = "created-id"
      private_key_path = File.join(directory, "#{certificate_id}.p12")
      write_created_outputs(directory, certificate_id, certificate, private_key)
      racer_content = "racer-must-survive"

      assert_raises(SigningPreparation::InvalidPlan) do
        SigningPreparation::EncryptedBackup.secure_created_identity!(
          directory: directory,
          certificate_id: certificate_id,
          password: "backup-secret",
          before_replace: lambda do
            racer = File.join(directory, "racer")
            File.binwrite(racer, racer_content)
            File.rename(racer, private_key_path)
          end
        )
      end

      assert_equal racer_content, File.binread(private_key_path)
      assert_empty Dir.children(directory).grep(/immich-quarantine/)
    end
  end

  def test_plaintext_cleanup_preserves_racer_that_wins_just_before_move
    _, private_key = self_signed_identity("remove-race")

    Dir.mktmpdir do |directory|
      path = File.join(directory, "owned.p12")
      File.write(path, private_key.to_pem)
      racer_content = "racer-must-survive"

      SigningPreparation::EncryptedBackup.remove_plaintext_private_keys!(
        directory: directory,
        before_remove: lambda do
          racer = File.join(directory, "racer")
          File.binwrite(racer, racer_content)
          File.rename(racer, path)
        end
      )

      assert_equal racer_content, File.binread(path)
      assert_empty Dir.children(directory).grep(/immich-quarantine/)
    end
  end

  def test_portal_certificate_verifier_consumes_exact_id_and_fingerprint
    certificate, = self_signed_identity("portal")
    fingerprint = Digest::SHA256.hexdigest(certificate.to_der)
    portal_certificate = Struct.new(:id, :certificate_content).new(
      "portal-certificate-id",
      Base64.strict_encode64(certificate.to_der)
    )

    assert SigningPreparation::PortalCertificateVerifier.verify!(
      portal_certificate: portal_certificate,
      expected_id: "portal-certificate-id",
      expected_fingerprint: fingerprint
    )
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::PortalCertificateVerifier.verify!(
        portal_certificate: portal_certificate,
        expected_id: "another-id",
        expected_fingerprint: fingerprint
      )
    end
    assert_raises(SigningPreparation::InvalidPlan) do
      SigningPreparation::PortalCertificateVerifier.verify!(
        portal_certificate: portal_certificate,
        expected_id: "portal-certificate-id",
        expected_fingerprint: "0" * 64
      )
    end
  end

  def test_created_backup_is_rewritten_as_private_encrypted_matching_pkcs12
    certificate, private_key = self_signed_identity("created")

    Dir.mktmpdir do |directory|
      certificate_id = "created-id"
      write_created_outputs(directory, certificate_id, certificate, private_key)

      identity = SigningPreparation::EncryptedBackup.secure_created_identity!(
        directory: directory,
        certificate_id: certificate_id,
        password: "backup-secret"
      )

      assert_equal Digest::SHA256.hexdigest(certificate.to_der), identity.fingerprint
      assert_equal 0o600, File.stat(File.join(directory, "#{certificate_id}.p12")).mode & 0o777
      assert_raises(OpenSSL::PKCS12::PKCS12Error) do
        OpenSSL::PKCS12.new(File.binread(File.join(directory, "#{certificate_id}.p12")), "")
      end
    end
  end

  private

  def profile_with_certificate(certificate)
    {
      "Entitlements" => { "application-identifier" => "portal-team.com.example.app" },
      "DeveloperCertificates" => [certificate]
    }
  end

  def create_plan(directory)
    SigningPreparation::Plan.from_env(
      IMPORT_ENV.reject { |name, _| name == "SIGNING_P12_PATH" || name.start_with?("SIGNING_CERTIFICATE") }.merge(
        "SIGNING_PREPARATION_MODE" => "create_authorized",
        "SIGNING_CREATE_AUTHORIZED" => "true",
        "SIGNING_BACKUP_DIRECTORY" => directory
      ),
      api_key_configuration: TEAM_KEY
    )
  end

  def write_created_outputs(directory, certificate_id, certificate, private_key)
    File.binwrite(File.join(directory, "#{certificate_id}.cer"), certificate.to_der)
    File.write(File.join(directory, "#{certificate_id}.certSigningRequest"), "request")
    File.write(File.join(directory, "#{certificate_id}.p12"), private_key.to_pem)
  end

  def self_signed_identity(common_name)
    key = OpenSSL::PKey::RSA.new(2048)
    certificate = OpenSSL::X509::Certificate.new
    certificate.serial = 1
    certificate.version = 2
    certificate.subject = OpenSSL::X509::Name.parse("/CN=#{common_name}")
    certificate.issuer = certificate.subject
    certificate.public_key = key.public_key
    certificate.not_before = Time.now - 60
    certificate.not_after = Time.now + 3600
    certificate.sign(key, OpenSSL::Digest::SHA256.new)
    [certificate, key]
  end
end

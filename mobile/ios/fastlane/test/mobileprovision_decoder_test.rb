# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../mobileprovision_decoder"

class MobileProvisionDecoderTest < Minitest::Test
  Result = Struct.new(:stdout, :stderr, :exit_status, keyword_init: true)

  class RecordingRunner
    attr_reader :calls

    def initialize(results)
      @results = results
      @calls = []
    end

    def call(argv)
      @calls << argv
      @results.fetch(@calls.length - 1)
    end
  end

  def test_security_success_does_not_invoke_openssl
    with_profile do |path|
      runner = RecordingRunner.new([
        Result.new(stdout: plist("UUID" => "security-uuid"), stderr: "diagnostic", exit_status: 0)
      ])

      decoded = decoder(runner).call(path)

      assert_equal "security-uuid", decoded.fetch("UUID")
      assert_equal [["/usr/bin/security", "cms", "-D", "-i", path]], runner.calls
    end
  end

  def test_security_nonzero_falls_back_to_openssl
    with_profile do |path|
      runner = RecordingRunner.new([
        Result.new(stdout: "", stderr: "security failed", exit_status: 1),
        Result.new(stdout: plist("UUID" => "openssl-uuid"), stderr: "CMS Verification successful", exit_status: 0)
      ])

      decoded = decoder(runner).call(path)

      assert_equal "openssl-uuid", decoded.fetch("UUID")
      assert_equal [
        ["/usr/bin/security", "cms", "-D", "-i", path],
        ["/usr/bin/openssl", "cms", "-verify", "-inform", "DER", "-noverify", "-in", path]
      ], runner.calls
    end
  end

  def test_security_invalid_plist_falls_back_to_openssl
    with_profile do |path|
      runner = RecordingRunner.new([
        Result.new(stdout: "not a plist", stderr: "", exit_status: 0),
        Result.new(stdout: plist("UUID" => "openssl-uuid"), stderr: "", exit_status: 0)
      ])

      assert_equal "openssl-uuid", decoder(runner).call(path).fetch("UUID")
      assert_equal 2, runner.calls.length
    end
  end

  def test_both_backends_fail_with_one_sanitized_error
    with_profile("private-profile-contents") do |path|
      runner = RecordingRunner.new([
        Result.new(stdout: "secret stdout", stderr: "secret stderr", exit_status: 1),
        Result.new(stdout: "also not a plist", stderr: "#{path}: private failure", exit_status: 0)
      ])

      error = assert_raises(MobileProvisionDecoder::Error) { decoder(runner).call(path) }

      assert_equal "Provisioning profile could not be decoded", error.message
      refute_includes error.message, path
      refute_includes error.message, "secret"
      refute_includes error.message, "private"
    end
  end

  def test_rejects_oversized_input_before_invoking_a_backend
    Dir.mktmpdir do |directory|
      path = File.join(directory, "oversized.mobileprovision")
      File.open(path, "wb") { |file| file.truncate(MobileProvisionDecoder::Decoder::MAX_PROFILE_BYTES + 1) }
      runner = RecordingRunner.new([])

      error = assert_raises(MobileProvisionDecoder::Error) { decoder(runner).call(path) }

      assert_equal "Provisioning profile could not be decoded", error.message
      assert_empty runner.calls
    end
  end

  def test_rejects_oversized_stdout_and_tries_the_fallback
    with_profile do |path|
      runner = RecordingRunner.new([
        Result.new(
          stdout: "x" * (MobileProvisionDecoder::Decoder::MAX_DECODED_BYTES + 1),
          stderr: "",
          exit_status: 0
        ),
        Result.new(stdout: plist("UUID" => "openssl-uuid"), stderr: "", exit_status: 0)
      ])

      assert_equal "openssl-uuid", decoder(runner).call(path).fetch("UUID")
      assert_equal 2, runner.calls.length
    end
  end

  def test_rejects_a_parseable_non_dictionary_plist
    with_profile do |path|
      runner = RecordingRunner.new([
        Result.new(stdout: plist_array("value"), stderr: "", exit_status: 0),
        Result.new(stdout: plist_array("other"), stderr: "", exit_status: 0)
      ])

      assert_raises(MobileProvisionDecoder::Error) { decoder(runner).call(path) }
    end
  end

  private

  def decoder(runner)
    MobileProvisionDecoder::Decoder.new(argv_runner: runner)
  end

  def with_profile(contents = "profile")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "release.mobileprovision")
      File.binwrite(path, contents)
      yield path
    end
  end

  def plist(values)
    entries = values.map { |key, value| "<key>#{key}</key><string>#{value}</string>" }.join
    plist_document("<dict>#{entries}</dict>")
  end

  def plist_array(value)
    plist_document("<array><string>#{value}</string></array>")
  end

  def plist_document(root)
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" \
      "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" " \
      "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" \
      "<plist version=\"1.0\">#{root}</plist>"
  end
end

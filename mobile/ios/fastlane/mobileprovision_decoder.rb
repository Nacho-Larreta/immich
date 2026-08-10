# frozen_string_literal: true

require "cfpropertylist"

module MobileProvisionDecoder
  class Error < StandardError; end
  FAILURE_MESSAGE = "Provisioning profile could not be decoded"

  class Decoder
    SECURITY = "/usr/bin/security"
    OPENSSL = "/usr/bin/openssl"
    MAX_PROFILE_BYTES = 8 * 1024 * 1024
    MAX_DECODED_BYTES = 8 * 1024 * 1024

    def initialize(argv_runner:)
      @argv_runner = argv_runner
    end

    def call(path)
      validate_profile!(path)
      backend_commands(path).each do |argv|
        decoded = decode(argv)
        return decoded if decoded
      end

      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE
    rescue Error
      raise
    rescue StandardError
      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE
    end

    private

    def validate_profile!(path)
      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE unless path.is_a?(String) && !path.empty?

      stat = File.lstat(path)
      valid = stat.file? && !stat.symlink? && stat.nlink == 1 && stat.uid == Process.euid &&
              stat.size.positive? && stat.size <= MAX_PROFILE_BYTES
      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE unless valid
    rescue Error
      raise
    rescue StandardError
      raise Error, MobileProvisionDecoder::FAILURE_MESSAGE
    end

    def backend_commands(path)
      [
        [SECURITY, "cms", "-D", "-i", path],
        [OPENSSL, "cms", "-verify", "-inform", "DER", "-noverify", "-in", path]
      ]
    end

    def decode(argv)
      result = @argv_runner.call(frozen_argv(argv))
      return unless successful_result?(result)

      values = CFPropertyList.native_types(CFPropertyList::List.new(data: result.stdout).value)
      values if values.is_a?(Hash)
    rescue StandardError
      nil
    end

    def frozen_argv(argv)
      argv.map { |argument| argument.dup.freeze }.freeze
    end

    def successful_result?(result)
      result.respond_to?(:stdout) && result.respond_to?(:exit_status) &&
        result.exit_status == 0 && result.stdout.is_a?(String) &&
        !result.stdout.empty? && result.stdout.bytesize <= MAX_DECODED_BYTES
    end
  end
end

# frozen_string_literal: true

module TestFlightConnectApiGateway
  class Error < StandardError; end
  class Unauthorized < Error; end
  class AuthenticationFailure < Error; end
  class Conflict < Error; end
  class AmbiguousMutation < Error; end
  class TransportAmbiguous < Error; end
  class RemoteFailure < Error; end

  class RemoteResponseError < Error
    attr_reader :status, :retry_after

    def initialize(status:, body: nil, retry_after: nil)
      @status = status
      @retry_after = retry_after
      super("Remote response failure")
    end
  end
end

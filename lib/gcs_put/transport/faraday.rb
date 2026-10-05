# frozen_string_literal: true

require "faraday"

# Uses a Faraday connection, so you can pick the adapter, timeouts and instrumentation yourself.
# Check the bytes arrive intact with whatever adapter you choose - we send a `Content-MD5` with
# every chunk precisely because httpx 1.4.0 used to mangle request bodies,
# see https://gitlab.com/os85/httpx/-/issues/338
class GCSPut::Transport::Faraday
  TRANSIENT_ERRORS = [::Faraday::ConnectionFailed, ::Faraday::TimeoutError, ::Faraday::SSLError].freeze

  # @param connection[Faraday::Connection, nil] a connection of your own, or `nil` to get a default one
  def initialize(connection = nil)
    @owns_connection = connection.nil?
    @connection = connection || ::Faraday.new
  end

  def put(uri, body, headers)
    request(:put, uri, body, headers)
  end

  def post(uri, body, headers)
    request(:post, uri, body, headers)
  end

  # A connection you passed in is yours to close, we only close the one we made
  def close
    @connection.close if @owns_connection && @connection.respond_to?(:close)
  end

  private

  def request(verb, uri, body, headers)
    response = @connection.run_request(verb, uri.to_s, body, headers)
    GCSPut::Transport::Response.new(response.status, response.headers, response.body)
  rescue *TRANSIENT_ERRORS => e
    raise GCSPut::TransientError, "#{e.class}: #{e.message}"
  rescue ::Faraday::Error => e
    # The `raise_error` middleware turns 4xx and 5xx into exceptions, we want the response back
    raise unless e.response
    GCSPut::Transport::Response.new(e.response_status, e.response_headers, e.response_body)
  end
end

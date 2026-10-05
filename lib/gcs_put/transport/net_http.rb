# frozen_string_literal: true

require "net/http"

# Keeps one connection per host open for the duration of the upload
class GcsPut::Transport::NetHTTP
  TRANSIENT_ERRORS = [
    IOError, EOFError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
    Net::WriteTimeout, OpenSSL::SSL::SSLError
  ].freeze

  # @param http_options[Hash] forwarded to `Net::HTTP.start` (`open_timeout:`, `read_timeout:`...)
  def initialize(**http_options)
    @http_options = http_options
    @connections = {}
  end

  def put(uri, body, headers)
    request(Net::HTTP::Put, uri, body, headers)
  end

  def post(uri, body, headers)
    request(Net::HTTP::Post, uri, body, headers)
  end

  def close
    @connections.each_value do |connection|
      connection.finish if connection.started?
    rescue IOError
      # Already gone, which is what we wanted
    end
    @connections.clear
  end

  private

  def request(request_class, uri, body, headers)
    request = request_class.new(uri, headers)
    request.body = body
    response = connection_for(uri).request(request)
    GcsPut::Transport::Response.new(response.code, response.each_header.to_h, response.body)
  rescue *TRANSIENT_ERRORS => e
    close
    raise GcsPut::TransientError, "#{e.class}: #{e.message}"
  end

  def connection_for(uri)
    @connections[[uri.host, uri.port]] ||= Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", **@http_options)
  end
end

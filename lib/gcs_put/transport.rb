# frozen_string_literal: true

# The uploader needs two HTTP verbs and does not care what performs them. A transport is any
# object with `put(uri, body, headers)`, `post(uri, body, headers)` and `close`, where the verbs
# return a `Transport::Response`. Failures worth retrying (connection resets, timeouts and the
# like) must surface as `GcsPut::TransientError` so the uploader knows it may query
# the session and carry on. Anything else is allowed to propagate.
module GcsPut::Transport
  autoload :NetHTTP, "gcs_put/transport/net_http"
  autoload :Faraday, "gcs_put/transport/faraday"

  class Response
    attr_reader :status, :headers, :body

    # @param status[#to_i]
    # @param headers[#to_h] header names in any case
    # @param body[#to_s]
    def initialize(status, headers, body)
      @status = status.to_i
      @headers = headers.to_h.transform_keys { |name| name.to_s.downcase }
      @body = body.to_s
    end

    # @param name[String] header name in any case
    # @return [String, nil]
    def [](name)
      @headers[name.to_s.downcase]
    end
  end
end

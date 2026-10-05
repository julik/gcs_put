# frozen_string_literal: true

require "test_helper"

class TransportTest < Minitest::Test
  URL = "https://storage.googleapis.com/bucket/object"

  def test_response_looks_up_headers_in_any_case
    response = GCSPut::Transport::Response.new("308", {"Range" => "bytes=0-9", :"x-guploader-uploadid" => "abc"}, nil)
    assert_equal 308, response.status
    assert_equal "bytes=0-9", response["range"]
    assert_equal "bytes=0-9", response["RANGE"]
    assert_equal "abc", response["X-GUploader-UploadID"]
    assert_nil response["Location"]
    assert_equal "", response.body
  end

  def test_net_http_wraps_connection_errors_as_transient
    stub_request(:put, URL).to_raise(Errno::ECONNRESET)
    transport = GCSPut::Transport::NetHTTP.new
    err = assert_raises(GCSPut::TransientError) { transport.put(URI(URL), "x", {}) }
    assert_match(/ECONNRESET/, err.message)
  end

  def test_net_http_wraps_timeouts_as_transient
    stub_request(:put, URL).to_timeout
    transport = GCSPut::Transport::NetHTTP.new
    assert_raises(GCSPut::TransientError) { transport.put(URI(URL), "x", {}) }
  end

  def test_faraday_wraps_connection_errors_as_transient
    stub_request(:put, URL).to_raise(Errno::ECONNRESET)
    transport = GCSPut::Transport::Faraday.new
    assert_raises(GCSPut::TransientError) { transport.put(URI(URL), "x", {}) }
  end

  def test_faraday_wraps_timeouts_as_transient
    stub_request(:put, URL).to_timeout
    transport = GCSPut::Transport::Faraday.new
    assert_raises(GCSPut::TransientError) { transport.put(URI(URL), "x", {}) }
  end

  def test_faraday_returns_error_statuses_as_responses_even_with_raise_error
    stub_request(:post, URL).to_return(status: 503, body: "busy", headers: {"Retry-After" => "1"})
    transport = GCSPut::Transport::Faraday.new(Faraday.new { |f| f.response :raise_error })
    response = transport.post(URI(URL), "", {})
    assert_equal 503, response.status
    assert_equal "busy", response.body
    assert_equal "1", response["retry-after"]
  end

  def test_both_transports_send_body_and_headers_verbatim
    stub_request(:put, URL).with(body: "payload", headers: {"Content-Range" => "bytes 0-6/*", "X-Custom" => "yes"}).to_return(status: 308, headers: {"Range" => "bytes=0-6"})
    [GCSPut::Transport::NetHTTP.new, GCSPut::Transport::Faraday.new].each do |transport|
      response = transport.put(URI(URL), "payload", {"Content-Range" => "bytes 0-6/*", "X-Custom" => "yes"})
      assert_equal 308, response.status
      assert_equal "bytes=0-6", response["Range"]
      transport.close
    end
  end
end

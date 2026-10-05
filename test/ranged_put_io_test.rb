# frozen_string_literal: true

require "test_helper"

# The same suite runs once per transport, see the classes at the bottom
module RangedPutIOTests
  SESSION_URL = "https://storage.googleapis.com/bucket/object?uploadType=resumable&upload_id=abc"
  UNIT = GcsPut::CHUNK_SIZE_UNIT

  def setup
    @puts = []
  end

  def new_io(**options)
    GcsPut::RangedPutIO.new(SESSION_URL, transport: transport, **options)
  end

  # Records every PUT and answers with whatever the block decides for it
  def stub_puts
    stub_request(:put, SESSION_URL).to_return do |request|
      @puts << {range: request.headers["Content-Range"], length: request.headers["Content-Length"].to_i, body: request.body}
      yield(request, @puts.size)
    end
  end

  def ack_whole_chunk(request)
    to = request.headers["Content-Range"].scan(/\d+/)[1].to_i
    is_last = !request.headers["Content-Range"].end_with?("/*")
    if is_last
      {status: 200, body: "{}"}
    else
      {status: 308, headers: {"Range" => "bytes=0-#{to}"}}
    end
  end

  def test_sends_ranged_puts_and_a_sized_final_put
    stub_puts { |request, _| ack_whole_chunk(request) }

    io = new_io(chunk_size: UNIT, content_type: "text/plain")
    io.write("a" * UNIT)
    io.write("b" * UNIT)
    io.write("c" * 10)
    total = io.finish

    assert_equal UNIT * 2 + 10, total
    assert_equal ["bytes 0-#{UNIT - 1}/*", "bytes #{UNIT}-#{UNIT * 2 - 1}/*", "bytes #{UNIT * 2}-#{UNIT * 2 + 9}/#{UNIT * 2 + 10}"], @puts.map { |p| p[:range] }
    assert_equal [UNIT, UNIT, 10], @puts.map { |p| p[:length] }
    assert_equal "c" * 10, @puts.last[:body]
  end

  def test_sends_every_put_with_content_type_and_md5
    stub_puts do |request, _|
      assert_equal "text/plain", request.headers["Content-Type"]
      assert_equal Digest::MD5.base64digest(request.body), request.headers["Content-Md5"]
      ack_whole_chunk(request)
    end

    io = new_io(chunk_size: UNIT, content_type: "text/plain")
    io << ("x" * (UNIT + 1))
    io.finish
    assert_equal 2, @puts.size
  end

  def test_an_empty_upload_sends_a_single_star_range_put
    stub_puts { |_, _| {status: 200, body: "{}"} }

    io = new_io(chunk_size: UNIT)
    assert_equal 0, io.finish
    assert_equal ["bytes */0"], @puts.map { |p| p[:range] }
  end

  def test_an_upload_ending_exactly_on_a_chunk_boundary_sizes_the_last_put
    stub_puts { |request, _| ack_whole_chunk(request) }

    io = new_io(chunk_size: UNIT)
    io << ("x" * UNIT * 2)
    io.finish
    assert_equal ["bytes 0-#{UNIT - 1}/*", "bytes #{UNIT}-#{UNIT * 2 - 1}/#{UNIT * 2}"], @puts.map { |p| p[:range] }
  end

  def test_resends_the_tail_of_a_chunk_gcs_only_partially_persisted
    stub_puts do |request, n|
      if n == 1
        {status: 308, headers: {"Range" => "bytes=0-#{UNIT - 1}"}} # only took the first 256K of a 512K chunk
      else
        ack_whole_chunk(request)
      end
    end

    io = new_io(chunk_size: UNIT * 2)
    io << ("a" * UNIT) << ("b" * UNIT) << "c"
    io.finish

    assert_equal ["bytes 0-#{UNIT * 2 - 1}/*", "bytes #{UNIT}-#{UNIT * 2 - 1}/*", "bytes #{UNIT * 2}-#{UNIT * 2}/#{UNIT * 2 + 1}"], @puts.map { |p| p[:range] }
    assert_equal "b" * UNIT, @puts[1][:body]
  end

  def test_resumes_from_the_queried_offset_after_a_server_error
    stub_puts do |request, n|
      case n
      when 1 then {status: 503, body: "nope"}
      when 2
        assert_equal "bytes */*", request.headers["Content-Range"] # the status check
        assert_equal 0, request.headers["Content-Length"].to_i
        {status: 308, headers: {"Range" => "bytes=0-#{UNIT - 1}"}}
      else ack_whole_chunk(request)
      end
    end

    io = new_io(chunk_size: UNIT * 2)
    io << ("a" * UNIT) << ("b" * UNIT) << "c"
    io.finish

    assert_equal ["bytes 0-#{UNIT * 2 - 1}/*", "bytes */*", "bytes #{UNIT}-#{UNIT * 2 - 1}/*", "bytes #{UNIT * 2}-#{UNIT * 2}/#{UNIT * 2 + 1}"], @puts.map { |p| p[:range] }
  end

  def test_resumes_after_a_connection_error
    calls = 0
    stub_request(:put, SESSION_URL).to_return do |request|
      calls += 1
      raise Errno::ECONNRESET if calls == 1
      if request.headers["Content-Range"] == "bytes */*"
        {status: 308} # nothing persisted, no Range header
      else
        ack_whole_chunk(request)
      end
    end

    io = new_io(chunk_size: UNIT)
    io << "hello"
    assert_equal 5, io.finish
    assert_equal 3, calls # failed PUT, status check, successful PUT
  end

  def test_treats_a_finalized_session_on_status_check_as_done
    stub_puts do |_, n|
      (n == 1) ? {status: 500} : {status: 200, body: "{}"}
    end

    io = new_io(chunk_size: UNIT)
    io << "hello"
    assert_equal 5, io.finish
    assert_equal 2, @puts.size # the 500 and the status check, no third PUT
  end

  def test_gives_up_after_max_attempts
    stub_puts { |_, _| {status: 503} }

    io = new_io(chunk_size: UNIT, max_attempts: 3)
    io << "hello"
    err = assert_raises(GcsPut::UploadFailed) { io.finish }
    assert_match(/after 3 attempts/, err.message)
  end

  def test_does_not_retry_client_errors
    stub_puts { |_, _| {status: 400, body: "Invalid Content-Range"} }

    io = new_io(chunk_size: UNIT)
    io << "hello"
    err = assert_raises(GcsPut::UploadFailed) { io.finish }
    assert_equal 400, err.response.status
    assert_equal 1, @puts.size
  end

  def test_rejects_a_chunk_size_which_is_not_a_multiple_of_256k
    assert_raises(ArgumentError) { new_io(chunk_size: UNIT + 1) }
  end
end

class RangedPutIONetHTTPTest < Minitest::Test
  include RangedPutIOTests

  def transport
    GcsPut::Transport::NetHTTP.new
  end
end

class RangedPutIOFaradayTest < Minitest::Test
  include RangedPutIOTests

  def transport
    GcsPut::Transport::Faraday.new
  end
end

class RangedPutIOFaradayWithRaiseErrorTest < Minitest::Test
  include RangedPutIOTests

  # The `raise_error` middleware must not get in the way of our own status handling
  def transport
    GcsPut::Transport::Faraday.new(Faraday.new { |f| f.response :raise_error })
  end
end

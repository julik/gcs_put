# frozen_string_literal: true

require "test_helper"

# The chunk upload suite runs once per transport, see the classes at the bottom
module ResumableUploadChunkTests
  SESSION_URL = "https://storage.googleapis.com/bucket/object?uploadType=resumable&upload_id=abc"
  UNIT = GCSPut::CHUNK_SIZE_UNIT

  def setup
    @puts = []
  end

  def new_io(**options)
    GCSPut::ResumableUpload.to_session_url(SESSION_URL, transport: transport, **options)
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
    err = assert_raises(GCSPut::UploadFailed) { io.finish }
    assert_match(/after 3 attempts/, err.message)
  end

  def test_does_not_retry_client_errors
    stub_puts { |_, _| {status: 400, body: "Invalid Content-Range"} }

    io = new_io(chunk_size: UNIT)
    io << "hello"
    err = assert_raises(GCSPut::UploadFailed) { io.finish }
    assert_equal 400, err.response.status
    assert_equal 1, @puts.size
  end

  def test_rejects_a_chunk_size_which_is_not_a_multiple_of_256k
    assert_raises(ArgumentError) { new_io(chunk_size: UNIT + 1) }
  end
end

class ResumableUploadNetHTTPTest < Minitest::Test
  include ResumableUploadChunkTests

  def transport
    GCSPut::Transport::NetHTTP.new
  end
end

class ResumableUploadFaradayTest < Minitest::Test
  include ResumableUploadChunkTests

  def transport
    GCSPut::Transport::Faraday.new
  end
end

class ResumableUploadFaradayWithRaiseErrorTest < Minitest::Test
  include ResumableUploadChunkTests

  # The `raise_error` middleware must not get in the way of our own status handling
  def transport
    GCSPut::Transport::Faraday.new(Faraday.new { |f| f.response :raise_error })
  end
end

class ResumableUploadSessionTest < Minitest::Test
  SIGNED_POST_URL = "https://storage.googleapis.com/bucket/object?X-Goog-Signature=sig"
  SESSION_URL = "https://storage.googleapis.com/upload/storage/v1/b/bucket/o?uploadType=resumable&upload_id=abc"

  # Stands in for a Google::Cloud::Storage::File
  FakeGCSFile = Struct.new(:signed_url_calls) do
    def signed_url(**options)
      signed_url_calls << options
      SIGNED_POST_URL
    end
  end

  def gcs_file
    @gcs_file ||= FakeGCSFile.new([])
  end

  # Keeps the test away from the metadata server lookup
  def with_signer_options(options)
    singleton = GCSPut::Signer.singleton_class
    original = GCSPut::Signer.method(:url_issuer_and_signer)
    singleton.send(:remove_method, :url_issuer_and_signer)
    singleton.send(:define_method, :url_issuer_and_signer) { options }
    yield
  ensure
    singleton.send(:remove_method, :url_issuer_and_signer)
    singleton.send(:define_method, :url_issuer_and_signer, original)
  end

  def test_to_gcs_file_signs_starts_the_session_and_streams_into_it
    stub_request(:post, SIGNED_POST_URL).with(headers: {"x-goog-resumable" => "start", "Content-Type" => "text/plain"}).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    total = with_signer_options({}) do
      GCSPut::ResumableUpload.to_gcs_file(gcs_file, content_type: "text/plain") { |io| io.write("hello") }
    end

    assert_equal 5, total
    assert_equal [{method: "POST", content_type: "text/plain", headers: {"x-goog-resumable" => "start"}}], gcs_file.signed_url_calls
    assert_requested(:put, SESSION_URL, headers: {"Content-Range" => "bytes 0-4/5", "Content-Type" => "text/plain"})
  end

  def test_to_gcs_file_without_a_block_returns_an_upload_to_drive_by_hand
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    upload = with_signer_options({}) { GCSPut::ResumableUpload.to_gcs_file(gcs_file) }
    assert_equal SESSION_URL, upload.session_url
    assert_equal 0, upload.bytes_persisted
    upload << "hello"
    assert_equal 5, upload.finish
    assert_equal 5, upload.bytes_persisted
  end

  def test_to_gcs_file_fails_when_the_session_start_is_refused
    stub_request(:post, SIGNED_POST_URL).to_return(status: 403, body: "denied")

    err = assert_raises(GCSPut::UploadFailed) do
      with_signer_options({}) { GCSPut::ResumableUpload.to_gcs_file(gcs_file) }
    end
    assert_match(/HTTP 403/, err.message)
    assert_equal 403, err.response.status
    assert_not_requested(:put, SESSION_URL)
  end

  def test_to_gcs_file_passes_issuer_signer_and_extra_options_through_to_signed_url
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201, headers: {"Location" => SESSION_URL})
    signer = ->(string_to_sign) { "sig" }

    with_signer_options({issuer: "sa@example.iam.gserviceaccount.com", signer: signer}) do
      GCSPut::ResumableUpload.to_gcs_file(gcs_file, signed_url_options: {expires: 300})
    end

    options = gcs_file.signed_url_calls.first
    assert_equal "sa@example.iam.gserviceaccount.com", options[:issuer]
    assert_equal signer, options[:signer]
    assert_equal 300, options[:expires]
  end

  def test_to_gcs_file_uses_the_given_transport_for_both_session_start_and_chunks
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    transport = GCSPut::Transport::Faraday.new
    total = with_signer_options({}) do
      GCSPut::ResumableUpload.to_gcs_file(gcs_file, transport: transport) { |io| io.write("hello") }
    end
    assert_equal 5, total
    assert_requested(:post, SIGNED_POST_URL)
    assert_requested(:put, SESSION_URL)
  end

  def test_to_signed_post_url_starts_the_session_and_streams_into_it
    stub_request(:post, SIGNED_POST_URL).with(headers: {"Content-Type" => "text/plain", "x-goog-resumable" => "start"}).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    total = GCSPut::ResumableUpload.to_signed_post_url(SIGNED_POST_URL, content_type: "text/plain") { |io| io.write("hello") }
    assert_equal 5, total
    assert_requested(:put, SESSION_URL, headers: {"Content-Range" => "bytes 0-4/5", "Content-Type" => "text/plain"})
  end

  def test_to_signed_post_url_without_a_block_returns_the_upload
    stub_request(:post, SIGNED_POST_URL).with(headers: {"Content-Type" => "binary/octet-stream", "x-goog-resumable" => "start"}).to_return(status: 201, headers: {"Location" => SESSION_URL})
    upload = GCSPut::ResumableUpload.to_signed_post_url(SIGNED_POST_URL)
    assert_equal SESSION_URL, upload.session_url
    assert_not_requested(:put, SESSION_URL)
  end

  def test_to_session_url_defaults_to_octet_stream_net_http_and_5mb_chunks
    stub_request(:put, SESSION_URL).with(headers: {"Content-Type" => "binary/octet-stream"}).to_return(status: 200, body: "{}")
    total = GCSPut::ResumableUpload.to_session_url(SESSION_URL) { |io| io.write("hello") }
    assert_equal 5, total
    upload = GCSPut::ResumableUpload.to_session_url(SESSION_URL)
    assert_kind_of GCSPut::Transport::NetHTTP, upload.instance_variable_get(:@transport)
    assert_equal 5 * 1024 * 1024, GCSPut::DEFAULT_CHUNK_SIZE
  end

  def test_to_gcs_file_defaults_to_octet_stream
    stub_request(:post, SIGNED_POST_URL).with(headers: {"Content-Type" => "binary/octet-stream"}).to_return(status: 201, headers: {"Location" => SESSION_URL})
    upload = with_signer_options({}) { GCSPut::ResumableUpload.to_gcs_file(gcs_file) }
    assert_equal SESSION_URL, upload.session_url
    assert_equal "binary/octet-stream", gcs_file.signed_url_calls.first[:content_type]
  end

  def test_close_finishes_so_gzip_writer_can_drive_it
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    upload = GCSPut.to_session_url(SESSION_URL)
    gz = Zlib::GzipWriter.new(upload)
    gz.write("hello")
    gz.close # closes the upload too

    assert_equal upload.bytes_persisted, upload.finish # already finished, a no-op
    assert_equal "hello", Zlib.gunzip(WebMock::RequestRegistry.instance.requested_signatures.hash.keys.find { |sig| sig.method == :put }.body)
  end

  def test_factories_are_available_on_the_top_level_module
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    assert_equal 5, with_signer_options({}) { GCSPut.to_gcs_file(gcs_file) { |io| io.write("hello") } }
    assert_equal 5, GCSPut.to_signed_post_url(SIGNED_POST_URL) { |io| io.write("hello") }
    assert_equal 5, GCSPut.to_session_url(SESSION_URL) { |io| io.write("hello") }
    assert_kind_of GCSPut::ResumableUpload, GCSPut.to_session_url(SESSION_URL)
  end

  def test_to_signed_post_url_fails_without_a_location
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201)
    err = assert_raises(GCSPut::UploadFailed) { GCSPut::ResumableUpload.to_signed_post_url(SIGNED_POST_URL) }
    assert_match(/Location/, err.message)
  end
end

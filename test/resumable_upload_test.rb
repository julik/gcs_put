# frozen_string_literal: true

require "test_helper"

class ResumableUploadTest < Minitest::Test
  SIGNED_POST_URL = "https://storage.googleapis.com/bucket/object?X-Goog-Signature=sig"
  SESSION_URL = "https://storage.googleapis.com/upload/storage/v1/b/bucket/o?uploadType=resumable&upload_id=abc"

  # Stands in for a Google::Cloud::Storage::File
  FakeFile = Struct.new(:signed_url_calls) do
    def signed_url(**options)
      signed_url_calls << options
      SIGNED_POST_URL
    end
  end

  def setup
    @upload = with_signer_options({}) { GcsPut::ResumableUpload.new(fake_file, content_type: "text/plain") }
  end

  # Keeps the test away from the metadata server lookup
  def with_signer_options(options)
    singleton = GcsPut::Signer.singleton_class
    original = GcsPut::Signer.method(:url_issuer_and_signer)
    singleton.send(:remove_method, :url_issuer_and_signer)
    singleton.send(:define_method, :url_issuer_and_signer) { options }
    yield
  ensure
    singleton.send(:remove_method, :url_issuer_and_signer)
    singleton.send(:define_method, :url_issuer_and_signer, original)
  end

  def fake_file
    @fake_file ||= FakeFile.new([])
  end

  def test_starts_the_session_with_a_signed_post_and_streams_into_it
    stub_request(:post, SIGNED_POST_URL).with(headers: {"x-goog-resumable" => "start", "Content-Type" => "text/plain"}).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    total = @upload.stream { |io| io.write("hello") }

    assert_equal 5, total
    assert_equal 1, fake_file.signed_url_calls.size
    assert_equal({method: "POST", content_type: "text/plain", headers: {"x-goog-resumable" => "start"}}, fake_file.signed_url_calls.first)
    assert_requested(:put, SESSION_URL, headers: {"Content-Range" => "bytes 0-4/5"})
  end

  def test_fails_when_the_session_start_is_refused
    stub_request(:post, SIGNED_POST_URL).to_return(status: 403, body: "denied")

    err = assert_raises(GcsPut::UploadFailed) { @upload.stream { |io| io.write("hello") } }
    assert_match(/HTTP 403/, err.message)
    assert_equal 403, err.response.status
  end

  def test_uses_the_given_transport_for_both_session_start_and_chunks
    stub_request(:post, SIGNED_POST_URL).to_return(status: 201, headers: {"Location" => SESSION_URL})
    stub_request(:put, SESSION_URL).to_return(status: 200, body: "{}")

    transport = GcsPut::Transport::Faraday.new
    upload = with_signer_options({}) { GcsPut::ResumableUpload.new(fake_file, transport: transport) }
    assert_equal 5, upload.stream { |io| io.write("hello") }
    assert_requested(:post, SIGNED_POST_URL)
    assert_requested(:put, SESSION_URL)
  end

  def test_passes_issuer_and_signer_through_to_signed_url
    signer = ->(string_to_sign) { "sig" }
    with_signer_options({issuer: "sa@example.iam.gserviceaccount.com", signer: signer}) do
      GcsPut::ResumableUpload.new(fake_file, expires: 300).start_session
    end
  rescue GcsPut::UploadFailed, WebMock::NetConnectNotAllowedError
    # The POST is not stubbed on purpose, we only care about the signed_url options
  ensure
    options = fake_file.signed_url_calls.first
    assert_equal "sa@example.iam.gserviceaccount.com", options[:issuer]
    assert_equal signer, options[:signer]
    assert_equal 300, options[:expires]
  end
end

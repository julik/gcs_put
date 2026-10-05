# frozen_string_literal: true

require "test_helper"

# Runs against a real bucket. Needs GOOGLE_APPLICATION_CREDENTIALS (or metadata server credentials)
# and GCS_PUT_TEST_BUCKET set, otherwise the whole class is skipped
class LiveUploadTest < Minitest::Test
  def setup
    skip "Set GCS_PUT_TEST_BUCKET to run live tests" unless ENV["GCS_PUT_TEST_BUCKET"]
    WebMock.disable!
    require "google/cloud/storage"
    @bucket = Google::Cloud::Storage.new.bucket(ENV["GCS_PUT_TEST_BUCKET"])
    @files = []
  end

  def teardown
    @files.each do |f|
      f.delete
    rescue Google::Cloud::Error
      # Never got created, fine
    end
    WebMock.enable!
  end

  def new_file
    name = "gcs-put-test-#{Random.bytes(4).unpack1("H*")}.bin"
    @bucket.file(name, skip_lookup: true).tap { |f| @files << f }
  end

  def wait_until_exists(file)
    20.times do
      return if file.exists?
      sleep 0.25
    end
    flunk "#{file.name} never appeared"
  end

  def test_uploads_something_smaller_than_a_chunk
    file = new_file
    GCSPut::ResumableUpload.new(file).stream { |io| io.write("Hello from a tiny resumable upload") }

    wait_until_exists(file)
    assert_equal "Hello from a tiny resumable upload", file.download.read
  end

  def test_uploads_something_spanning_multiple_chunks
    rng = Random.new(Minitest.seed)
    file = new_file
    size = (5 * 1024 * 1024 + 1) * 2
    GCSPut::ResumableUpload.new(file, content_type: "x-top-secret/binary").stream do |io|
      2.times { io.write(rng.bytes(5 * 1024 * 1024 + 1)) }
    end

    wait_until_exists(file)
    assert_equal size, file.size
    assert_equal "x-top-secret/binary", file.content_type
  end
end

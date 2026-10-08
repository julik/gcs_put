# frozen_string_literal: true

require "test_helper"

# Runs against a real bucket and skips when it cannot find one. Credentials and project come from
# the usual places the SDK looks - GOOGLE_APPLICATION_CREDENTIALS and GOOGLE_CLOUD_PROJECT, or the
# gcloud application-default login. The bucket is "gcs_put_test_bucket" unless GCS_PUT_TEST_BUCKET says otherwise
class LiveUploadTest < Minitest::Test
  BUCKET_NAME = ENV.fetch("GCS_PUT_TEST_BUCKET", "gcs_put_test_bucket")

  def setup
    WebMock.disable!
    @bucket, skip_reason = self.class.bucket_lookup
    skip skip_reason unless @bucket
    @files = []
  end

  def teardown
    @files&.each do |f|
      f.delete
    rescue Google::Cloud::Error
      # Never got created, fine
    end
    WebMock.enable!
  end

  # Looked up once per process so that a missing configuration costs one round trip, not one per test
  def self.bucket_lookup
    @bucket_lookup ||= begin
      require "google/cloud/storage"
      bucket = Google::Cloud::Storage.new.bucket(BUCKET_NAME)
      bucket ? [bucket, nil] : [nil, "Bucket #{BUCKET_NAME} not found, live tests skipped"]
    rescue => e
      [nil, "No usable GCP configuration (#{e.class}: #{e.message.lines.first.strip}), live tests skipped"]
    end
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
    gcs_file = new_file
    GCSPut::ResumableUpload.with_gcs_file(gcs_file) { |io| io.write("Hello from a tiny resumable upload") }

    wait_until_exists(gcs_file)
    assert_equal "Hello from a tiny resumable upload", gcs_file.download.read
  end

  def test_uploads_something_spanning_multiple_chunks
    rng = Random.new(Minitest.seed)
    gcs_file = new_file
    size = (5 * 1024 * 1024 + 1) * 2
    GCSPut::ResumableUpload.with_gcs_file(gcs_file, content_type: "x-top-secret/binary") do |io|
      2.times { io.write(rng.bytes(5 * 1024 * 1024 + 1)) }
    end

    wait_until_exists(gcs_file)
    assert_equal size, gcs_file.size
    assert_equal "x-top-secret/binary", gcs_file.content_type
  end

  def test_uploads_with_a_customer_supplied_encryption_key
    key = Random.bytes(32)
    csek = {
      "x-goog-encryption-algorithm" => "AES256",
      "x-goog-encryption-key" => [key].pack("m0"),
      "x-goog-encryption-key-sha256" => Digest::SHA256.base64digest(key)
    }
    gcs_file = new_file
    GCSPut::ResumableUpload.with_gcs_file(gcs_file, headers: csek) { |io| io.write("Hello from an encrypted upload") }

    wait_until_exists(gcs_file)
    assert_raises(Google::Cloud::Error) { gcs_file.download }
    # With an encryption_key the SDK hands back the StringIO without rewinding it
    assert_equal "Hello from an encrypted upload", gcs_file.download(encryption_key: key).string
  end
end

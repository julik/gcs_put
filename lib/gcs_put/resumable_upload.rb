# frozen_string_literal: true

# Starts a resumable upload session for a `Google::Cloud::Storage::File` and gives you
# a writable to stream into.
#
#   file = bucket.file("upload.bin", skip_lookup: true)
#   GCSPut::ResumableUpload.new(file).stream do |io|
#     io.write("Hello resumable")
#     20.times { io.write(Random.bytes(1024 * 1024)) }
#   end
#
# Starting the session needs a signed POST URL, and signing needs a private key. Under
# workload identity there is no key, so we fall back to the IAM signBlob API - which means
# the service account must hold `roles/iam.serviceAccountTokenCreator` on itself. See
# https://github.com/googleapis/google-cloud-ruby/issues/13307
class GCSPut::ResumableUpload
  # @param file[Google::Cloud::Storage::File] the object to upload into, may not exist yet
  # @param content_type[String] the content type of the resulting object
  # @param chunk_size[Integer] must be a multiple of 256 KiB
  # @param transport[#put, #post, #close] see `GCSPut::Transport`
  # @param signed_url_options[Hash] passed to `file.signed_url`, see `Signer.url_issuer_and_signer`
  def initialize(file, content_type: "binary/octet-stream", chunk_size: GCSPut::DEFAULT_CHUNK_SIZE, transport: GCSPut::Transport::NetHTTP.new, **signed_url_options)
    @file = file
    @content_type = content_type
    @chunk_size = chunk_size
    @transport = transport
    @signed_url_options = GCSPut::Signer.url_issuer_and_signer.merge(signed_url_options)
  end

  # Starts the session, yields a writable and closes the object once the block returns
  #
  # @yield [GCSPut::RangedPutIO] an object responding to `write` and `<<`
  # @return [Integer] the total number of bytes uploaded
  def stream
    writable = GCSPut::RangedPutIO.new(start_session, chunk_size: @chunk_size, content_type: @content_type, transport: @transport)
    yield(writable)
    writable.finish
  end

  # @return [String] the session URL, which stays valid for a week and can be used from any process
  def start_session
    signed_post_url = @file.signed_url(method: "POST", content_type: @content_type, headers: {"x-goog-resumable" => "start"}, **@signed_url_options)
    self.class.start_session(signed_post_url, content_type: @content_type, transport: @transport)
  end

  # Turns a signed POST URL (one with `x-goog-resumable: start` in its signed headers) into a session URL,
  # see https://cloud.google.com/storage/docs/performing-resumable-uploads#initiate-session
  #
  # @param signed_post_url[String]
  # @param content_type[String] must match the content type the URL was signed with
  # @param transport[#put, #post, #close] see `GCSPut::Transport`
  # @return [String] the session URL to hand to `RangedPutIO`
  def self.start_session(signed_post_url, content_type:, transport: GCSPut::Transport::NetHTTP.new)
    response = transport.post(URI(signed_post_url), "", {"Content-Type" => content_type, "x-goog-resumable" => "start"})
    unless response.status == 201
      raise GCSPut::UploadFailed.new("Session start responded with HTTP #{response.status}: #{response.body}", response: response)
    end
    response["Location"] or raise GCSPut::UploadFailed.new("Session start did not return a Location header", response: response)
  end
end

# frozen_string_literal: true

# A writable object which streams what you write into a GCS resumable upload session using
# ranged PUTs, see https://cloud.google.com/storage/docs/performing-resumable-uploads#chunked-upload
# You do not need to know the size of the output in advance. You do need to `finish` the upload,
# since it is the last PUT (with the total size filled in) which closes the GCS object.
#
#   gcs_file = bucket.file("upload.bin", skip_lookup: true)
#   GCSPut::ResumableUpload.from_gcs_file(gcs_file) do |io|
#     io.write("Hello resumable")
#     20.times { io.write(Random.bytes(1024 * 1024)) }
#   end
#
# Every chunk is retried from the byte offset GCS reports as persisted, so a chunk which
# only partially made it over the wire gets topped up rather than resent from the start.
#
# Starting the session needs a signed POST URL, and signing needs a private key. Under
# workload identity there is no key, so we fall back to the IAM signBlob API - which means
# the service account must hold `roles/iam.serviceAccountTokenCreator` on itself. See
# https://github.com/googleapis/google-cloud-ruby/issues/13307
class GCSPut::ResumableUpload
  extend Forwardable

  def_delegators :@chunker, :write, :<<

  # @return [String] the session URL, valid for a week and usable from any process
  attr_reader :session_url

  # @return [Integer] the number of bytes GCS has confirmed as persisted so far
  attr_reader :bytes_persisted

  # Signs a session start URL for the object, starts the session and returns the upload.
  # With a block, yields the upload, finishes it once the block returns and returns the total size.
  #
  # @param gcs_file[Google::Cloud::Storage::File] the object to upload into, does not need to exist yet
  # @param content_type[String] the content type of the resulting object
  # @param transport[#put, #post, #close] see `GCSPut::Transport`
  # @param signed_url_options[Hash] passed to `gcs_file.signed_url`, see `Signer.url_issuer_and_signer`
  # @param options[Hash] see `from_session_url`
  # @return [GCSPut::ResumableUpload, Integer]
  def self.from_gcs_file(gcs_file, content_type: "binary/octet-stream", transport: GCSPut::Transport::NetHTTP.new, signed_url_options: {}, **options, &blk)
    signed_url_options = GCSPut::Signer.url_issuer_and_signer.merge(signed_url_options)
    signed_post_url = gcs_file.signed_url(method: "POST", content_type: content_type, headers: {"x-goog-resumable" => "start"}, **signed_url_options)
    session_url = start_session(signed_post_url, content_type: content_type, transport: transport)
    from_session_url(session_url, content_type: content_type, transport: transport, **options, &blk)
  end

  # Wraps an already started session. With a block, yields the upload, finishes it once
  # the block returns and returns the total size.
  #
  # @param session_url[String] the `Location` returned by the session start
  # @param content_type[String] must match the content type the session was started with
  # @param chunk_size[Integer] must be a multiple of 256 KiB
  # @param max_attempts[Integer] how many times a single chunk may be sent before giving up
  # @param transport[#put, #post, #close] see `GCSPut::Transport`
  # @return [GCSPut::ResumableUpload, Integer]
  def self.from_session_url(session_url, **options)
    upload = new(session_url, **options)
    return upload unless block_given?
    yield(upload)
    upload.finish
  end

  # Turns a signed POST URL (one with `x-goog-resumable: start` among its signed headers) into a session URL,
  # see https://cloud.google.com/storage/docs/performing-resumable-uploads#initiate-session
  #
  # @param signed_post_url[String]
  # @param content_type[String] must match the content type the URL was signed with
  # @param transport[#put, #post, #close] see `GCSPut::Transport`
  # @return [String] the session URL
  def self.start_session(signed_post_url, content_type:, transport: GCSPut::Transport::NetHTTP.new)
    response = transport.post(URI(signed_post_url), "", {"Content-Type" => content_type, "x-goog-resumable" => "start"})
    unless response.status == 201
      raise GCSPut::UploadFailed.new("Session start responded with HTTP #{response.status}: #{response.body}", response: response)
    end
    response["Location"] or raise GCSPut::UploadFailed.new("Session start did not return a Location header", response: response)
  end

  def initialize(session_url, chunk_size: GCSPut::DEFAULT_CHUNK_SIZE, content_type: "binary/octet-stream", max_attempts: 5, transport: GCSPut::Transport::NetHTTP.new)
    unless (chunk_size % GCSPut::CHUNK_SIZE_UNIT).zero?
      raise ArgumentError, "chunk_size of #{chunk_size} is not a multiple of #{GCSPut::CHUNK_SIZE_UNIT}"
    end

    @session_url = session_url
    @session_uri = URI(session_url)
    @content_type = content_type
    @max_attempts = max_attempts
    @transport = transport
    @bytes_persisted = 0
    @finished = false
    @chunker = GCSPut::ByteChunker.new(chunk_size: chunk_size) { |bytes, is_last| upload_chunk(bytes, is_last) }
  end

  # Sends the remaining buffered bytes as the final chunk and closes the GCS object
  #
  # @return [Integer] the total number of bytes uploaded
  def finish
    return @bytes_persisted if @finished
    @chunker.finish
    @finished = true
    @bytes_persisted
  ensure
    @transport.close
  end

  private

  def upload_chunk(chunk, is_last)
    chunk_start = @bytes_persisted
    chunk_end = chunk_start + chunk.bytesize
    total = is_last ? chunk_end : "*"
    attempts = 0

    loop do
      attempts += 1
      if @bytes_persisted < chunk_start
        raise GCSPut::UploadFailed, "GCS reports #{@bytes_persisted} bytes persisted but we already discarded everything before #{chunk_start}"
      end
      body = chunk.byteslice(@bytes_persisted - chunk_start, chunk.bytesize)

      begin
        response = put_bytes(body, from: @bytes_persisted, total: total)
        failure = "HTTP #{response.status}"
      rescue GCSPut::TransientError => e
        response = nil
        failure = e.message
      end

      case response&.status.to_i
      when 200, 201
        @bytes_persisted = chunk_end
        return
      when 308
        @bytes_persisted = persisted_offset_from(response)
        return if @bytes_persisted == chunk_end && !is_last
        # GCS took fewer bytes than we sent, or wants the sized finalizing PUT - send the rest
      when 500..599, 408, 429, 0
        if sync_with_session_finds_it_finalized?
          @bytes_persisted = chunk_end
          return
        end
      else
        raise GCSPut::UploadFailed.new("Chunk PUT responded with HTTP #{response.status}: #{response.body}", response: response)
      end

      if attempts >= @max_attempts
        raise GCSPut::UploadFailed, "Gave up on chunk at offset #{chunk_start} after #{attempts} attempts, last failure: #{failure}"
      end
    end
  end

  def put_bytes(body, from:, total:)
    content_range = if body.empty?
      "bytes */#{total}"
    else
      "bytes #{from}-#{from + body.bytesize - 1}/#{total}"
    end
    headers = {
      "Content-Length" => body.bytesize.to_s,
      "Content-Range" => content_range,
      "Content-Type" => @content_type,
      # Lets GCS reject a chunk mangled in transit instead of us discovering it at download time
      "Content-MD5" => Digest::MD5.base64digest(body)
    }
    @transport.put(@session_uri, body, headers)
  end

  # Asks GCS how much of the upload it has and updates `bytes_persisted` accordingly, see
  # https://cloud.google.com/storage/docs/performing-resumable-uploads#status-check
  # A status check which fails itself just leaves us with what we already knew
  #
  # @return [Boolean] whether the session turned out to be finalized already
  def sync_with_session_finds_it_finalized?
    response = @transport.put(@session_uri, "", {"Content-Length" => "0", "Content-Range" => "bytes */*", "Content-Type" => @content_type})
    case response.status
    when 308
      @bytes_persisted = persisted_offset_from(response)
      false
    when 200, 201
      true
    when 500..599, 408, 429
      false
    else
      raise GCSPut::UploadFailed.new("Session status check responded with HTTP #{response.status}: #{response.body}", response: response)
    end
  rescue GCSPut::TransientError
    false
  end

  # The `Range` header is "bytes=0-N" with N being the last persisted byte, and absent if nothing persisted yet
  def persisted_offset_from(response)
    range = response["Range"]
    return 0 unless range
    range[/\d+\z/].to_i + 1
  end
end

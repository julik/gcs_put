# frozen_string_literal: true

# A writable object which sends what you write to it into a GCS resumable upload session
# using ranged PUTs, see https://cloud.google.com/storage/docs/performing-resumable-uploads#chunked-upload
# You do not need to know the size of the output in advance. You do need to `finish` the object,
# since it is the last PUT (with the total size filled in) which closes the GCS object.
#
# Every chunk is retried from the byte offset GCS reports as persisted, so a chunk which
# only partially made it over the wire gets topped up rather than resent from the start.
class GcsPut::RangedPutIO
  extend Forwardable

  def_delegators :@chunker, :write, :<<

  # @return [Integer] the number of bytes GCS has confirmed as persisted so far
  attr_reader :bytes_persisted

  # @param session_url[String] the resumable upload session URL (the `Location` from the session start)
  # @param chunk_size[Integer] must be a multiple of 256 KiB
  # @param content_type[String] sent with every PUT
  # @param max_attempts[Integer] how many times a single chunk may be sent before giving up
  # @param transport[#put, #post, #close] see `GcsPut::Transport`
  def initialize(session_url, chunk_size: GcsPut::DEFAULT_CHUNK_SIZE, content_type: "binary/octet-stream", max_attempts: 5, transport: GcsPut::Transport::NetHTTP.new)
    unless (chunk_size % GcsPut::CHUNK_SIZE_UNIT).zero?
      raise ArgumentError, "chunk_size of #{chunk_size} is not a multiple of #{GcsPut::CHUNK_SIZE_UNIT}"
    end

    @session_uri = URI(session_url)
    @content_type = content_type
    @max_attempts = max_attempts
    @transport = transport
    @bytes_persisted = 0
    @finished = false
    @chunker = GcsPut::ByteChunker.new(chunk_size: chunk_size) { |bytes, is_last| upload_chunk(bytes, is_last) }
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
        raise GcsPut::UploadFailed, "GCS reports #{@bytes_persisted} bytes persisted but we already discarded everything before #{chunk_start}"
      end
      body = chunk.byteslice(@bytes_persisted - chunk_start, chunk.bytesize)

      begin
        response = put_bytes(body, from: @bytes_persisted, total: total)
        failure = "HTTP #{response.status}"
      rescue GcsPut::TransientError => e
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
        raise GcsPut::UploadFailed.new("Chunk PUT responded with HTTP #{response.status}: #{response.body}", response: response)
      end

      if attempts >= @max_attempts
        raise GcsPut::UploadFailed, "Gave up on chunk at offset #{chunk_start} after #{attempts} attempts, last failure: #{failure}"
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
      raise GcsPut::UploadFailed.new("Session status check responded with HTTP #{response.status}: #{response.body}", response: response)
    end
  rescue GcsPut::TransientError
    false
  end

  # The `Range` header is "bytes=0-N" with N being the last persisted byte, and absent if nothing persisted yet
  def persisted_offset_from(response)
    range = response["Range"]
    return 0 unless range
    range[/\d+\z/].to_i + 1
  end
end

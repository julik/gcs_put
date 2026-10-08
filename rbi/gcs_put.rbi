# typed: strong
# The Ruby GCP SDK can only upload things it can measure in advance. GCS itself has supported
# resumable uploads of unknown size for ages though. This gem gives you a writable object
# which chops what you write to it into correctly sized chunks and PUTs them into a
# resumable upload session, so you never need to know the size up front.
module GCSPut
  extend Forwardable
  CHUNK_SIZE_UNIT = T.let(256 * 1024, T.untyped)
  DEFAULT_CHUNK_SIZE = T.let(5 * 1024 * 1024, T.untyped)
  VERSION = T.let("0.2.0", T.untyped)

  # Base class for everything the gem raises
  class Error < StandardError
  end

  # Raised by transports for failures worth retrying - connection resets, timeouts and the like
  class TransientError < GCSPut::Error
  end

  # Raised when GCS answers a chunk PUT with something we cannot recover from
  class UploadFailed < GCSPut::Error
    # _@param_ `message`
    # 
    # _@param_ `response`
    sig { params(message: String, response: T.nilable(GCSPut::Transport::Response)).void }
    def initialize(message, response: nil); end

    # _@return_ — the response which caused the failure, if there was one
    sig { returns(T.nilable(GCSPut::Transport::Response)) }
    attr_reader :response
  end

  # Supplies the `issuer` and `signer` that `Google::Cloud::Storage::File#signed_url` needs
  # when there is no private key around to sign with
  module Signer
    # When running on GCE, GKE, Cloud Run etc. under a service account there is no private key
    # on the box to sign the URL with. The SDK then needs an `issuer` (the account email) and a
    # `signer` lambda which asks the IAM credentials API to sign for us. For that to be allowed the
    # service account must have `roles/iam.serviceAccountTokenCreator` on itself.
    # Lifted from https://github.com/googleapis/google-cloud-ruby/issues/13307#issuecomment-1894546343
    # 
    # _@return_ — either `{issuer:, signer:}` or an empty hash when not on compute engine
    sig { returns(T::Hash[T.untyped, T.untyped]) }
    def self.url_issuer_and_signer; end

    # _@param_ `service_account_email`
    # 
    # _@return_ — a lambda which takes the string to sign and returns the signature
    sig { params(service_account_email: String).returns(Proc) }
    def self.iam_signer_for(service_account_email); end
  end

  # The uploader needs two HTTP verbs and does not care what performs them. A transport is any
  # object with `put(uri, body, headers)`, `post(uri, body, headers)` and `close`, where the verbs
  # return a `Transport::Response`. Failures worth retrying (connection resets, timeouts and the
  # like) must surface as `GCSPut::TransientError` so the uploader knows it may query
  # the session and carry on. Anything else is allowed to propagate.
  module Transport
    # What a transport hands back from `put` and `post`
    class Response
      # sord duck - #to_i looks like a duck type, replacing with untyped
      # sord duck - #to_h looks like a duck type, replacing with untyped
      # sord duck - #to_s looks like a duck type, replacing with untyped
      # _@param_ `status`
      # 
      # _@param_ `headers` — header names in any case
      # 
      # _@param_ `body`
      sig { params(status: T.untyped, headers: T.untyped, body: T.untyped).void }
      def initialize(status, headers, body); end

      # _@param_ `name` — header name in any case
      sig { params(name: String).returns(T.nilable(String)) }
      def [](name); end

      # _@return_ — the HTTP status code
      sig { returns(Integer) }
      attr_reader :status

      # _@return_ — the headers, with lowercased names
      sig { returns(T::Hash[String, String]) }
      attr_reader :headers

      # _@return_ — the body, empty if there was none
      sig { returns(String) }
      attr_reader :body
    end

    # Uses a Faraday connection, so you can pick the adapter, timeouts and instrumentation yourself.
    # Check the bytes arrive intact with whatever adapter you choose - we send a `Content-MD5` with
    # every chunk precisely because httpx 1.4.0 used to mangle request bodies,
    # see https://gitlab.com/os85/httpx/-/issues/338
    class Faraday
      TRANSIENT_ERRORS = T.let([::Faraday::ConnectionFailed, ::Faraday::TimeoutError, ::Faraday::SSLError].freeze, T.untyped)

      # sord warn - Faraday::Connection wasn't able to be resolved to a constant in this project
      # _@param_ `connection` — a connection of your own, or `nil` to get a default one
      sig { params(connection: T.nilable(Faraday::Connection)).void }
      def initialize(connection = nil); end

      # sord warn - URI::Generic wasn't able to be resolved to a constant in this project
      # _@param_ `uri`
      # 
      # _@param_ `body`
      # 
      # _@param_ `headers`
      sig { params(uri: URI::Generic, body: String, headers: T::Hash[String, String]).returns(GCSPut::Transport::Response) }
      def put(uri, body, headers); end

      # sord warn - URI::Generic wasn't able to be resolved to a constant in this project
      # _@param_ `uri`
      # 
      # _@param_ `body`
      # 
      # _@param_ `headers`
      sig { params(uri: URI::Generic, body: String, headers: T::Hash[String, String]).returns(GCSPut::Transport::Response) }
      def post(uri, body, headers); end

      # A connection you passed in is yours to close, we only close the one we made
      sig { void }
      def close; end

      # sord omit - no YARD type given for "verb", using untyped
      # sord omit - no YARD type given for "uri", using untyped
      # sord omit - no YARD type given for "body", using untyped
      # sord omit - no YARD type given for "headers", using untyped
      # sord omit - no YARD return type given, using untyped
      sig do
        params(
          verb: T.untyped,
          uri: T.untyped,
          body: T.untyped,
          headers: T.untyped
        ).returns(T.untyped)
      end
      def request(verb, uri, body, headers); end
    end

    # Keeps one connection per host open for the duration of the upload
    class NetHTTP
      TRANSIENT_ERRORS = T.let([
  IOError, EOFError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout,
  Net::WriteTimeout, OpenSSL::SSL::SSLError
].freeze, T.untyped)

      # _@param_ `http_options` — forwarded to `Net::HTTP.start` (`open_timeout:`, `read_timeout:`...)
      sig { params(http_options: T::Hash[T.untyped, T.untyped]).void }
      def initialize(**http_options); end

      # sord warn - URI::Generic wasn't able to be resolved to a constant in this project
      # _@param_ `uri`
      # 
      # _@param_ `body`
      # 
      # _@param_ `headers`
      sig { params(uri: URI::Generic, body: String, headers: T::Hash[String, String]).returns(GCSPut::Transport::Response) }
      def put(uri, body, headers); end

      # sord warn - URI::Generic wasn't able to be resolved to a constant in this project
      # _@param_ `uri`
      # 
      # _@param_ `body`
      # 
      # _@param_ `headers`
      sig { params(uri: URI::Generic, body: String, headers: T::Hash[String, String]).returns(GCSPut::Transport::Response) }
      def post(uri, body, headers); end

      # Closes the kept connections. Safe to call repeatedly, the next request reopens as needed
      sig { void }
      def close; end

      # sord omit - no YARD type given for "request_class", using untyped
      # sord omit - no YARD type given for "uri", using untyped
      # sord omit - no YARD type given for "body", using untyped
      # sord omit - no YARD type given for "headers", using untyped
      # sord omit - no YARD return type given, using untyped
      sig do
        params(
          request_class: T.untyped,
          uri: T.untyped,
          body: T.untyped,
          headers: T.untyped
        ).returns(T.untyped)
      end
      def request(request_class, uri, body, headers); end

      # sord omit - no YARD type given for "uri", using untyped
      # sord omit - no YARD return type given, using untyped
      sig { params(uri: T.untyped).returns(T.untyped) }
      def connection_for(uri); end
    end
  end

  # Chops an arbitrary stream of writes into evenly sized chunks. Every chunk except the last
  # will be exactly `chunk_size` bytes, and the last one can be anything from 0 bytes up to and
  # including `chunk_size`. A chunk which fills up exactly is held back until `finish` so that
  # a stream ending on a chunk boundary still delivers that chunk flagged as the last one.
  # 
  #   chunker = ByteChunker.new(chunk_size: 3) { |bytes, is_last| puts [bytes, is_last].inspect }
  #   chunker << "ab" << "cdefg"  # => ["abc", false], ["def", false]
  #   chunker.finish              # => ["g", true]
  class ByteChunker
    # _@param_ `chunk_size` — the size that every chunk except the last must have
    sig { params(chunk_size: Integer, delivery_proc: T.untyped).void }
    def initialize(chunk_size:, &delivery_proc); end

    # _@param_ `bin_str` — the bytes to append
    sig { params(bin_str: String).returns(T.self_type) }
    def <<(bin_str); end

    # _@param_ `bin_str` — the bytes to append
    # 
    # _@return_ — the number of bytes appended, like `IO#write`
    sig { params(bin_str: String).returns(Integer) }
    def write(bin_str); end

    # Delivers whatever is left in the buffer as the last chunk. The last chunk
    # gets delivered even when empty - it is what closes the upload
    sig { void }
    def finish; end

    sig { void }
    def deliver_full_chunks; end
  end

  # A writable object which streams what you write into a GCS resumable upload session using
  # ranged PUTs, see https://cloud.google.com/storage/docs/performing-resumable-uploads#chunked-upload
  # You do not need to know the size of the output in advance. You do need to `finish` the upload,
  # since it is the last PUT (with the total size filled in) which closes the GCS object.
  # 
  #   gcs_file = bucket.file("upload.bin", skip_lookup: true)
  #   GCSPut.with_gcs_file(gcs_file) do |io|
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
  class ResumableUpload
    extend Forwardable

    # Appends bytes to the upload, sending out a chunk whenever one fills up
    # 
    # _@param_ `bin_str`
    # 
    # _@return_ — the number of bytes appended, like `IO#write`
    sig { params(bin_str: String).returns(Integer) }
    def write(bin_str); end

    # Appends bytes to the upload, sending out a chunk whenever one fills up
    # 
    # _@param_ `bin_str`
    sig { params(bin_str: String).returns(T.self_type) }
    def <<(bin_str); end

    # sord warn - Google::Cloud::Storage::File wasn't able to be resolved to a constant in this project
    # sord duck - #put looks like a duck type, replacing with untyped
    # sord duck - #post looks like a duck type, replacing with untyped
    # sord duck - #close looks like a duck type, replacing with untyped
    # Signs a session start URL for the object, starts the session and returns the upload.
    # With a block, yields the upload, finishes it once the block returns and returns the total size.
    # 
    # _@param_ `gcs_file` — the object to upload into, does not need to exist yet
    # 
    # _@param_ `content_type` — the content type of the resulting object
    # 
    # _@param_ `transport` — see `GCSPut::Transport`
    # 
    # _@param_ `headers` — extra headers for the session start, signed into the URL and sent along with it - customer-supplied encryption keys, `Content-Disposition`, `x-goog-meta-*` and the like
    # 
    # _@param_ `signed_url_options` — passed to `gcs_file.signed_url`, see `Signer.url_issuer_and_signer`
    # 
    # _@param_ `options` — see {#initialize}
    # 
    # _@return_ — the upload, or the total size when given a block
    sig do
      params(
        gcs_file: Google::Cloud::Storage::File,
        content_type: String,
        transport: T.untyped,
        headers: T::Hash[T.untyped, T.untyped],
        signed_url_options: T::Hash[T.untyped, T.untyped],
        options: T::Hash[T.untyped, T.untyped],
        blk: T.untyped
      ).returns(T.any(GCSPut::ResumableUpload, Integer))
    end
    def self.with_gcs_file(gcs_file, content_type: "binary/octet-stream", transport: GCSPut::Transport::NetHTTP.new, headers: {}, signed_url_options: {}, **options, &blk); end

    # sord duck - #put looks like a duck type, replacing with untyped
    # sord duck - #post looks like a duck type, replacing with untyped
    # sord duck - #close looks like a duck type, replacing with untyped
    # Starts a session from a signed POST URL (one with `x-goog-resumable: start` among its signed headers)
    # and returns the upload, see https://cloud.google.com/storage/docs/performing-resumable-uploads#initiate-session
    # With a block, yields the upload, finishes it once the block returns and returns the total size.
    # 
    # _@param_ `signed_post_url`
    # 
    # _@param_ `content_type` — must match the content type the URL was signed with
    # 
    # _@param_ `transport` — see `GCSPut::Transport`
    # 
    # _@param_ `headers` — extra headers to send with the session start, must match the ones the URL was signed with. Only the session start needs them, chunks get uploaded without
    # 
    # _@param_ `options` — see {#initialize}
    # 
    # _@return_ — the upload, or the total size when given a block
    sig do
      params(
        signed_post_url: String,
        content_type: String,
        transport: T.untyped,
        headers: T::Hash[T.untyped, T.untyped],
        options: T::Hash[T.untyped, T.untyped],
        blk: T.untyped
      ).returns(T.any(GCSPut::ResumableUpload, Integer))
    end
    def self.with_signed_post_url(signed_post_url, content_type: "binary/octet-stream", transport: GCSPut::Transport::NetHTTP.new, headers: {}, **options, &blk); end

    # Wraps an already started session. With a block, yields the upload, finishes it once
    # the block returns and returns the total size.
    # 
    # _@param_ `session_url` — the `Location` returned by the session start
    # 
    # _@param_ `options` — see {#initialize}
    # 
    # _@return_ — the upload, or the total size when given a block
    sig { params(session_url: String, options: T::Hash[T.untyped, T.untyped]).returns(T.any(GCSPut::ResumableUpload, Integer)) }
    def self.with_session_url(session_url, **options); end

    # sord duck - #put looks like a duck type, replacing with untyped
    # sord duck - #post looks like a duck type, replacing with untyped
    # sord duck - #close looks like a duck type, replacing with untyped
    # Prefer the `with_*` factories. This does no HTTP by itself, the first request goes out
    # once a chunk fills up or `finish` gets called
    # 
    # _@param_ `session_url` — the `Location` returned by the session start
    # 
    # _@param_ `chunk_size` — must be a multiple of 256 KiB
    # 
    # _@param_ `content_type` — must match the content type the session was started with
    # 
    # _@param_ `max_attempts` — how many times a single chunk may be sent before giving up
    # 
    # _@param_ `transport` — see `GCSPut::Transport`
    sig do
      params(
        session_url: String,
        chunk_size: Integer,
        content_type: String,
        max_attempts: Integer,
        transport: T.untyped
      ).void
    end
    def initialize(session_url, chunk_size: GCSPut::DEFAULT_CHUNK_SIZE, content_type: "binary/octet-stream", max_attempts: 5, transport: GCSPut::Transport::NetHTTP.new); end

    # Sends the remaining buffered bytes as the final chunk and closes the GCS object.
    # Also available as `close` so that writers which close their underlying IO, like
    # `Zlib::GzipWriter`, finish the upload for you
    # 
    # _@return_ — the total number of bytes uploaded
    sig { returns(Integer) }
    def finish; end

    # _@param_ `chunk`
    # 
    # _@param_ `is_last`
    sig { params(chunk: String, is_last: T::Boolean).void }
    def upload_chunk(chunk, is_last); end

    # _@param_ `body`
    # 
    # _@param_ `from`
    # 
    # _@param_ `total` — the total size, or "*" while still unknown
    sig { params(body: String, from: Integer, total: T.any(Integer, String)).returns(GCSPut::Transport::Response) }
    def put_bytes(body, from:, total:); end

    # Asks GCS how much of the upload it has and updates `bytes_persisted` accordingly, see
    # https://cloud.google.com/storage/docs/performing-resumable-uploads#status-check
    # A status check which fails itself just leaves us with what we already knew
    # 
    # _@return_ — whether the session turned out to be finalized already
    sig { returns(T::Boolean) }
    def sync_with_session_finds_it_finalized?; end

    # The `Range` header is "bytes=0-N" with N being the last persisted byte, and absent if nothing persisted yet
    # 
    # _@param_ `response`
    sig { params(response: GCSPut::Transport::Response).returns(Integer) }
    def persisted_offset_from(response); end

    # _@return_ — the session URL, valid for a week and usable from any process
    sig { returns(String) }
    attr_reader :session_url

    # _@return_ — the number of bytes GCS has confirmed as persisted so far
    sig { returns(Integer) }
    attr_reader :bytes_persisted
  end
end

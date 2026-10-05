# frozen_string_literal: true

require "uri"
require "digest/md5"
require "forwardable"

# The Ruby GCP SDK can only upload things it can measure in advance. GCS itself has supported
# resumable uploads of unknown size for ages though. This gem gives you a writable object
# which chops what you write to it into correctly sized chunks and PUTs them into a
# resumable upload session, so you never need to know the size up front.
module GCSPut
  class Error < StandardError
  end

  # Raised by transports for failures worth retrying - connection resets, timeouts and the like
  class TransientError < Error
  end

  # Raised when GCS answers a chunk PUT with something we cannot recover from
  class UploadFailed < Error
    attr_reader :response

    def initialize(message, response: nil)
      super(message)
      @response = response
    end
  end

  # GCS insists that all chunks except the last are sized in multiples of this
  CHUNK_SIZE_UNIT = 256 * 1024

  # AWS recommend 5MB as the default part size for multipart uploads, and GCP recommend
  # doing "less requests" in general. Since we have to hold a buffer of this size anyway,
  # 5MB seems like a reasonable number for GCP too
  DEFAULT_CHUNK_SIZE = 5 * 1024 * 1024

  autoload :ByteChunker, "gcs_put/byte_chunker"
  autoload :ResumableUpload, "gcs_put/resumable_upload"
  autoload :Signer, "gcs_put/signer"
  autoload :Transport, "gcs_put/transport"

  class << self
    extend Forwardable

    def_delegators :"GCSPut::ResumableUpload", :from_gcs_file, :from_signed_post_url, :from_session_url
  end
end

require "gcs_put/version"

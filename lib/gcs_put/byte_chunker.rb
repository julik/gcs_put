# frozen_string_literal: true

# Chops an arbitrary stream of writes into evenly sized chunks. Every chunk except the last
# will be exactly `chunk_size` bytes, and the last one can be anything from 0 bytes up to and
# including `chunk_size`. A chunk which fills up exactly is held back until `finish` so that
# a stream ending on a chunk boundary still delivers that chunk flagged as the last one.
#
#   chunker = ByteChunker.new(chunk_size: 3) { |bytes, is_last| puts [bytes, is_last].inspect }
#   chunker << "ab" << "cdefg"  # => ["abc", false], ["def", false]
#   chunker.finish              # => ["g", true]
class GCSPut::ByteChunker
  # @param chunk_size[Integer] the size that every chunk except the last must have
  # @yield [bytes, is_last] a binary String and whether this is the final chunk
  def initialize(chunk_size:, &delivery_proc)
    raise ArgumentError, "chunk_size must be positive" unless chunk_size.to_i > 0
    @chunk_size = chunk_size.to_i
    # A mutable String with preallocated capacity beats a StringIO here - the buffer
    # gets reused for the whole life of the chunker and never reallocates
    @buf = String.new(encoding: Encoding::BINARY, capacity: @chunk_size * 2)
    @delivery_proc = delivery_proc.to_proc
  end

  # @param bin_str[String] the bytes to append
  # @return [self]
  def <<(bin_str)
    @buf << bin_str.b
    deliver_full_chunks
    self
  end

  # @param bin_str[String] the bytes to append
  # @return [Integer] the number of bytes appended, like `IO#write`
  def write(bin_str)
    self << bin_str
    bin_str.bytesize
  end

  # Delivers whatever is left in the buffer as the last chunk. The last chunk
  # gets delivered even when empty - it is what closes the upload
  #
  # @return [void]
  def finish
    deliver_full_chunks
    # Hand out a copy - the receiver may hold on to it, and we reuse the buffer
    @delivery_proc.call(@buf.byteslice(0, @buf.bytesize), _is_last = true)
    @buf.clear
    nil
  end

  private

  # @return [void]
  def deliver_full_chunks
    while @buf.bytesize > @chunk_size
      @delivery_proc.call(@buf.byteslice(0, @chunk_size), _is_last = false)
      @buf.replace(@buf.byteslice(@chunk_size..))
    end
  end
end

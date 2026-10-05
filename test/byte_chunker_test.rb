# frozen_string_literal: true

require "test_helper"

class ByteChunkerTest < Minitest::Test
  def chunker_class
    GCSPut::ByteChunker
  end

  def collecting_chunker(chunk_size)
    writes = []
    chunker = chunker_class.new(chunk_size: chunk_size) { |chunk, is_last| writes << chunk << is_last }
    [chunker, writes]
  end

  def test_reassembles_input_regardless_of_chunk_and_write_sizes
    rng = Random.new(Minitest.seed)

    32.times do
      chunk_size = rng.rand(1..512)
      flags = []
      out = StringIO.new.binmode
      chunker = chunker_class.new(chunk_size: chunk_size) do |bytes, is_last|
        out << bytes
        flags << is_last
      end

      blob = rng.bytes(rng.rand(1..1024))
      read_size = rng.rand(1..222)
      source = StringIO.new(blob)
      while (bytes = source.read(read_size))
        chunker << bytes
      end
      chunker.finish

      assert_equal blob, out.string
      *all_but_last, last = flags
      assert_equal [false], all_but_last.uniq if all_but_last.any?
      assert_equal true, last
    end
  end

  def test_holds_back_an_exactly_full_chunk_until_finish
    chunker, writes = collecting_chunker(3)
    chunker << "a" << "b" << "c"
    chunker.finish
    assert_equal ["abc", true], writes
  end

  def test_delivers_multiple_chunks_from_many_small_writes
    chunker, writes = collecting_chunker(7)
    ("a".."z").each { |char| chunker << char }
    chunker.finish
    assert_equal ["abcdefg", false, "hijklmn", false, "opqrstu", false, "vwxyz", true], writes
  end

  def test_delivers_multiple_chunks_from_a_single_write
    chunker, writes = collecting_chunker(7)
    chunker << ("a".."z").to_a.join
    chunker.finish
    assert_equal ["abcdefg", false, "hijklmn", false, "opqrstu", false, "vwxyz", true], writes
  end

  def test_delivers_a_short_last_chunk_when_the_only_write_is_below_chunk_size
    chunker, writes = collecting_chunker(3)
    chunker << "a"
    chunker.finish
    assert_equal ["a", true], writes
  end

  def test_delivers_an_empty_last_chunk_after_only_empty_writes
    chunker, writes = collecting_chunker(3)
    chunker << "" << ""
    chunker.finish
    assert_equal ["", true], writes
  end

  def test_delivers_an_empty_last_chunk_without_any_writes
    chunker, writes = collecting_chunker(3)
    chunker.finish
    assert_equal ["", true], writes
  end

  def test_write_returns_the_number_of_bytes_like_io
    chunker, _ = collecting_chunker(3)
    assert_equal 5, chunker.write("hello")
    assert_equal 6, chunker.write("héllo") # multibyte counts bytes, not characters
  end

  def test_delivered_chunks_are_binary
    chunker, writes = collecting_chunker(2)
    chunker << "abcd"
    chunker.finish
    writes.each_slice(2) { |chunk, _| assert_equal Encoding::BINARY, chunk.encoding }
  end

  def test_is_a_valid_destination_for_io_copy_stream
    rng = Random.new(Minitest.seed)
    blob = rng.bytes(rng.rand(1..64 * 1024))
    out = StringIO.new.binmode
    chunker = chunker_class.new(chunk_size: 777) { |bytes, _| out << bytes }

    copied = IO.copy_stream(StringIO.new(blob), chunker)
    chunker.finish

    assert_equal blob.bytesize, copied
    assert_equal blob, out.string
  end

  def test_rejects_a_non_positive_chunk_size
    assert_raises(ArgumentError) { chunker_class.new(chunk_size: 0) {} }
  end
end

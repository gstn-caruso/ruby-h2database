# frozen_string_literal: true

require_relative 'test_helper'
require 'h2/mvstore'
require 'stringio'
require 'tmpdir'

class StreamStoreTest < Minitest::Test
  M = H2::MVStore

  def test_original_format_vectors_and_indirect_blocks
    map = {}
    store = M::StreamStore.new(map,min_block_size: 10,max_block_size: 20)
    store.next_key = 123
    [200,0,1,3,10].zip(%w[02c8018801 EMPTY 000100 0003000000 010a8901]).each do |length,hex|
      id = store.put(StringIO.new("\0".b * length))
      assert_equal hex == 'EMPTY' ? '' : hex, id.unpack1('H*')
      assert_equal length, store.length(id)
      assert_equal "\0".b * length, store.get(id).read
    end
    assert_equal 138, store.next_key
  end

  def test_incremental_read_skip_eof_close_and_caller_input_ownership
    store = M::StreamStore.new({},min_block_size: 4,max_block_size: 8)
    input = StringIO.new(('a'..'z').to_a.join.b)
    id = store.put(input)
    refute input.closed?
    reader = store.get(id)
    assert_equal '', reader.read(0)
    assert_equal 'abc', reader.read(3)
    assert_equal 3, reader.pos
    assert_equal 2, reader.skip(2)
    assert_equal 'fghij', reader.read(5)
    assert_equal 'klmnopqrstuvwxyz', reader.read
    assert_nil reader.read(1)
    output = +'old'
    assert_nil reader.read(1,output)
    assert_equal '', output
    assert_equal '', reader.read
    assert reader.eof?
    reader.close
    assert reader.closed?
    assert_nil reader.getbyte
  end

  def test_partial_reads_short_input_reads_and_indirect_traversal_are_lazy
    map = Class.new(Hash) do
      attr_accessor :reads
      def [](key)
        self.reads = reads.to_i + 1
        super
      end
    end.new
    store = M::StreamStore.new(map,min_block_size: 10,max_block_size: 100)
    input = Class.new(StringIO) { def read(length) = super([length,3].min) }.new('x'.b * 10_000)
    id = store.put(input)
    map.reads = 0
    assert_equal 10_000, store.length(id)
    assert_equal 0, map.reads
    reader = store.get(id)
    assert_equal 0, map.reads
    assert_equal 'x', reader.read(1)
    assert_equal 3, map.reads
    assert_equal 'x' * 99, reader.readpartial(1000)
  end

  def test_remove_reclaims_only_the_stream_and_failed_input_reclaims_partial_writes
    map = {}
    counts = []
    store = M::StreamStore.new(map,min_block_size: 4,max_block_size: 8,on_store: ->(length) { counts << length })
    keep = store.put(StringIO.new('keep data'))
    id = store.put(StringIO.new('remove this payload'.b * 30))
    assert_equal map.keys.max, store.max_block_key(id)
    assert counts.all?(&:positive?)
    store.remove(id)
    assert_equal 'keep data', store.get(keep).read
    saved = map.dup
    failing = Class.new do
      def initialize = @calls = 0
      def read(length)
        @calls += 1
        raise 'broken input' if @calls > 3
        'x' * length
      end
    end.new
    error = assert_raises(IOError) { store.put(failing) }
    assert_instance_of RuntimeError, error.cause
    assert_equal saved, map
  end

  def test_missing_blocks_and_malformed_ids_fail_explicitly
    map = {}
    store = M::StreamStore.new(map,min_block_size: 1,max_block_size: 8)
    id = store.put(StringIO.new('missing'))
    map.clear
    reader = store.get(id)
    error = assert_raises(IOError) { reader.read }
    assert_equal 50, error.cause.code
    assert_equal 6, assert_raises(M::Error) { store.length("\x00\x08x".b) }.code
    assert_equal 6, assert_raises(M::Error) { store.length("\x03".b) }.code
  end

  def test_blob_metadata_and_reference_codecs_round_trip_and_register
    metadata = M::BlobMetadata.new("\x02\x80\x01\x09".b,-3,9_223_372_036_854_775_807,-1)
    reference = M::BlobReference.new("\x80\x00".b,300)
    [[metadata,M::Codecs::BLOB_META],[reference,M::Codecs::BLOB_REFERENCE]].each do |value,codec|
      buffer = M::Buffer.new
      codec.write(buffer,value)
      assert_equal value, codec.read(M::Buffer.new(buffer.data))
      descriptor = M::Buffer.new
      M::Codecs::META.write(descriptor,codec)
      assert_same codec, M::Codecs::META.read(M::Buffer.new(descriptor.data))
      assert value.stream_id.frozen?
    end
    assert_operator M::Codecs::BLOB_REFERENCE.compare(M::BlobReference.new("\xff".b,1),M::BlobReference.new("\x00".b,1)), :<, 0
    assert_operator M::Codecs::BLOB_REFERENCE.compare(M::BlobReference.new('x',1),M::BlobReference.new('aa',1)), :<, 0
  end

  def test_inline_skip_and_nonmonotone_indirect_keys_preserve_stream_invariants
    store = M::StreamStore.new({100 => "\x01".b,1 => "\x00\x01\x02".b})
    id = "\x01\x01\x64\x02\x01\x01".b
    assert_equal 100, store.max_block_key(id)
    reader = store.get(['0001aa0002bbcc0002ddee'].pack('H*'))
    assert_equal 2, reader.skip(2)
    assert_equal 'ccddee', reader.read.unpack1('H*')
    assert_equal 'indirect block 1 len=1, length=1', M::StreamStore.describe("\x02\x01\x01".b)
  end

  def test_transaction_maps_keep_stream_creation_and_removal_transactional
    Dir.mktmpdir('h2-stream-transactions') do |directory|
      M::TransactionStore.open(File.join(directory,'data.mv')) do |transactions|
        id = nil
        transactions.transaction do |transaction|
          map = transaction.open_map('streams',key_type: :long,value_type: :bytes)
          store = M::StreamStore.new(map,min_block_size: 4,max_block_size: 16)
          id = store.put(StringIO.new('transactional'.b * 20))
          assert map.key?(store.max_block_key(id))
        end
        transaction = transactions.begin_transaction
        map = transaction.open_map('streams')
        store = M::StreamStore.new(map)
        assert_equal 'transactional' * 20, store.get(id).read
        store.remove(id)
        assert_equal 0, map.size
        transaction.rollback
        transactions.transaction do |reader|
          assert_equal 'transactional' * 20, M::StreamStore.new(reader.open_map('streams')).get(id).read
        end
      end
    end
  end

  def test_concurrent_writers_allocate_distinct_blocks_without_losing_payloads
    store = M::StreamStore.new({},min_block_size: 4,max_block_size: 16)
    results = 8.times.map do |index|
      Thread.new { bytes = index.to_s.b * 200; [store.put(StringIO.new(bytes)),bytes] }
    end.map(&:value)
    results.each { |id,bytes| assert_equal bytes, store.get(id).read }
    results.each { |id,_bytes| store.remove(id) }
    assert_empty store.map
  end

  def test_key_search_preserves_existing_data_at_the_signed_long_boundary
    key = (1 << 63) - 1
    map = {key => 'original'}
    store = M::StreamStore.new(map,min_block_size: 1,max_block_size: 8)
    store.next_key = key
    assert_raises(RangeError) { store.put(StringIO.new('x')) }
    assert_equal 'original', map[key]
    store.next_key = -3
    map[-3] = 'negative'
    store.put(StringIO.new('y'))
    assert_equal 'negative', map[-3]
    store = M::StreamStore.new({},min_block_size: 4,max_block_size: 16)
    store.next_key = -5
    assert_equal(-4, store.max_block_key(store.put(StringIO.new('x' * 8))))
  end

  def test_original_key_search_counts_with_existing_and_very_full_maps
    counted = Class.new(Hash) do
      attr_accessor :checks, :full
      def key?(key)
        self.checks = checks.to_i + 1
        (full && key < ((1 << 63) - 1) / 2) || super
      end
    end
    map = counted.new
    store = M::StreamStore.new(map,min_block_size: 10,max_block_size: 20)
    10.times { store.put(StringIO.new('x' * 20)) }
    assert_equal 10, map.checks
    10.times { assert map.key?(it) }
    store = M::StreamStore.new(map,min_block_size: 10,max_block_size: 20)
    5.times { store.put(StringIO.new('x' * 20)) }
    assert_equal 88, map.checks
    assert_equal 15, store.next_key
    full = counted.new
    full.full = true
    store = M::StreamStore.new(full,min_block_size: 20,max_block_size: 100)
    store.put(StringIO.new('x' * 100))
    assert_equal 64, full.checks
    assert_equal ((1 << 63) - 1) / 2 + 1, store.next_key
  end

  def test_corrupt_indirection_cycles_are_rejected
    id = "\x02\x01\x00".b
    store = M::StreamStore.new({0 => id})
    assert_equal 6, assert_raises(M::Error) { store.get(id).read }.code
    assert_equal 6, assert_raises(M::Error) { store.max_block_key(id) }.code
    assert_equal 6, assert_raises(M::Error) { store.remove(id) }.code
  end

  def test_stream_data_and_lob_metadata_survive_native_file_reopen
    Dir.mktmpdir('h2-streams') do |directory|
      path = File.join(directory,'streams.mv')
      id = nil
      M::Store.open(path) do |store|
        blocks = store.open_registered_map('lobData',key_type: :long,value_type: :bytes)
        streams = M::StreamStore.new(blocks,min_block_size: 4,max_block_size: 16)
        id = streams.put(StringIO.new('payload'.b * 100))
        metadata = store.open_registered_map('lobMap',key_type: :long,value_type: :blob_meta)
        metadata[1] = M::BlobMetadata.new(id,7,700,0)
        assert blocks.key?(streams.max_block_key(id))
      end
      M::Store.open(path) do |store|
        blocks = store.open_map('lobData')
        metadata = store.open_map('lobMap')
        assert_equal 'payload' * 100, M::StreamStore.new(blocks).get(metadata[1].stream_id).read
      end
    end
  end
end

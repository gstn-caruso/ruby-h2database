# frozen_string_literal: true

require_relative 'test_helper'
require 'h2/mvstore'
require 'stringio'
require 'tmpdir'

class LobStorageTest < Minitest::Test
  M = H2::MVStore

  def with_storage(**options)
    Dir.mktmpdir('h2-lobs') do |directory|
      M::Store.open(File.join(directory,'lobs.mv')) do |raw|
        M::LobStorage.open(raw,**options) { |storage| yield storage,raw }
      end
    end
  end

  def test_known_small_values_are_inline_and_unknown_lengths_are_temporary
    with_storage do |storage,_raw|
      input = StringIO.new('abcdef'.b)
      value = storage.create_blob(input,max_length: 3)
      assert_equal :blob, value.type
      assert_equal 'abc', value.data
      assert_equal 3, input.pos
      refute input.closed?
      external = storage.create_blob(StringIO.new('abc'))
      assert_equal M::LobReference.new(-2,1,3,nil), external.data
      assert_equal 'abc', storage.open(external).read
    end
  end

  def test_copies_share_blocks_until_the_last_reference_is_removed
    with_storage do |storage,raw|
      original = storage.create_blob(StringIO.new('payload' * 1000))
      first = storage.copy_lob(original,table_id: 7)
      second = storage.copy_lob(first,table_id: 8)
      assert_equal 1, raw.open_map('lobData').size
      storage.remove_all_for_table(-2)
      storage.remove_all_for_table(7)
      storage.open(second) { |reader| assert_equal 'payload' * 1000, reader.read }
      assert_equal 1, raw.open_map('lobData').size
      storage.remove_all_for_table(8)
      assert_equal 0, raw.open_map('lobData').size
      assert_equal 0, raw.open_map('lobRef').size
    end
  end

  def test_deferred_cleanup_obeys_versions_and_open_readers
    with_storage do |storage,raw|
      value = storage.copy_lob(storage.create_blob(StringIO.new('x' * 1000)),table_id: 7)
      storage.remove_all_for_table(-2)
      reader = storage.open(value)
      assert_equal 'x', reader.read(1)
      storage.remove_lob(value)
      version = raw.version
      storage.cleanup(oldest_version: version)
      assert_equal 1, storage.pending_count
      storage.cleanup(oldest_version: version + 1)
      assert_equal 1, storage.pending_count
      assert_equal 'x' * 999, reader.read
      reader.close
      storage.cleanup(oldest_version: version + 1)
      assert_equal 0, storage.pending_count
      assert_equal 0, raw.open_map('lobData').size
    end
  end

  def test_character_limits_count_utf16_units_and_replace_split_surrogates
    with_storage do |storage,_raw|
      inline = storage.create_clob(StringIO.new('😀x'),max_length: 1)
      assert_equal M::InlineClob.new('?',1), inline.data
      external = storage.create_clob(StringIO.new('😀café' * 200))
      assert_equal 1200, external.data.characters
      storage.open(external) { |reader| assert_equal ('😀café' * 200).b, reader.read }
      invalid = [0xd800,97,0xdc00].pack('n*').force_encoding(Encoding::UTF_16BE)
      value = storage.create_clob(StringIO.new(invalid))
      assert_equal 3, value.data.characters
      storage.open(value) { |reader| assert_equal '?a?', reader.read }
    end
  end

  def test_permanent_values_and_id_allocation_reopen
    Dir.mktmpdir('h2-lob-reopen') do |directory|
      path = File.join(directory,'db.mv')
      value = nil
      M::Store.open(path) do |raw|
        storage = M::LobStorage.new(raw)
        value = storage.copy_lob(storage.create_blob(StringIO.new('x' * 300000)),table_id: 7)
        storage.close
      end
      M::Store.open(path) do |raw|
        storage = M::LobStorage.new(raw)
        storage.open(value) { |reader| assert_equal 'x' * 300000, reader.read }
        next_value = storage.create_blob(StringIO.new('later'))
        assert_operator next_value.data.lob_id, :>, value.data.lob_id
        storage.close
      end
      M::Store.open(path,read_only: true) do |raw|
        storage = M::LobStorage.new(raw)
        storage.open(value) { |reader| assert_equal 'x' * 300000, reader.read }
        assert_equal 2, assert_raises(M::Error) { storage.copy_lob(value,table_id: 8) }.code
        storage.close
      end
    end
  end

  def test_failures_do_not_publish_metadata_or_leak_stream_blocks
    with_storage do |storage,raw|
      input = Class.new do
        def initialize = @calls = 0
        def read(length)
          @calls += 1
          raise IOError, 'broken' if @calls == 3
          'x' * length
        end
      end.new
      assert_raises(IOError) { storage.create_blob(input) }
      %w[lobData lobMap lobRef tempLobMap].each { assert_equal 0, raw.open_map(it).size }
      assert_equal 50, assert_raises(M::Error) { storage.get_input_stream(99,table_id: 7) }.code
      assert_raises(ArgumentError) { storage.create_blob(StringIO.new('x'),max_length: -2) }
    end
  end

  def test_table_removal_does_not_force_other_tables_pending_cleanup
    with_storage do |storage,raw|
      source = storage.create_blob(StringIO.new('x' * 1000))
      first = storage.copy_lob(source,table_id: 7)
      second = storage.copy_lob(first,table_id: 8)
      storage.remove_all_for_table(-2)
      storage.remove_lob(second)
      storage.remove_all_for_table(7)
      assert_equal 1, storage.pending_count
      storage.open(second) { |reader| assert_equal 'x' * 1000, reader.read }
      storage.cleanup(oldest_version: raw.version + 1)
      assert_equal 0, raw.open_map('lobData').size
    end
  end

  def test_external_character_limits_stop_at_the_requested_utf16_length
    with_storage do |storage,_raw|
      value = storage.create_clob(StringIO.new('a' * 1000),max_length: 86)
      assert_equal 86, value.data.characters
      storage.open(value) { |reader| assert_equal 'a' * 86, reader.read }
    end
  end

  def test_only_one_active_lob_manager_can_allocate_ids_in_a_store
    with_storage do |storage,raw|
      assert_equal 103, assert_raises(M::Error) { M::LobStorage.new(raw) }.code
      storage.close
      M::LobStorage.open(raw) { |next_storage| assert_equal 1, next_storage.create_blob(StringIO.new('x')).data.lob_id }
      assert_equal 0, raw.open_map('tempLobMap').size
    end
  end

  def test_table_removal_waits_for_a_reader_and_releases_on_close
    with_storage do |storage,raw|
      value = storage.copy_lob(storage.create_blob(StringIO.new('x' * 300000)),table_id: 7)
      storage.remove_all_for_table(-2)
      reader = storage.open(value)
      storage.remove_all_for_table(7)
      assert_equal 'x' * 300000, reader.read
      assert_operator raw.open_map('lobData').size, :>, 0
      reader.close
      assert_equal 0, raw.open_map('lobData').size
    end
  end

  def test_large_character_limit_does_not_overflow_the_inline_decision
    with_storage do |storage,_raw|
      value = storage.create_clob(StringIO.new('abc'),max_length: 1 << 62)
      assert_equal 3, value.data.characters
      storage.open(value) { |reader| assert_equal 'abc', reader.read }
    end
  end

  def test_cleanup_does_not_rotate_a_future_entry_ahead_of_an_eligible_one
    with_storage do |storage,raw|
      first = storage.create_blob(StringIO.new('a'))
      second = storage.create_blob(StringIO.new('b'))
      storage.remove_lob(first)
      version = raw.version
      raw.commit
      storage.remove_lob(second)
      storage.cleanup(oldest_version: version)
      storage.cleanup(oldest_version: version + 1)
      assert_equal 1, raw.open_map('tempLobMap').size
      assert_equal 1, storage.pending_count
      storage.open(second) { |reader| assert_equal 'b', reader.read }
    end
  end

  def test_open_reader_keeps_later_blocks_available_during_cleanup
    with_storage do |storage,raw|
      value = storage.create_blob(StringIO.new('x' * 600000))
      reader = storage.open(value)
      assert_equal 'x', reader.read(1)
      storage.remove_lob(value)
      storage.cleanup(oldest_version: raw.version + 1)
      assert_equal 'x' * 599999, reader.read
      reader.close
      storage.cleanup(oldest_version: raw.version + 1)
      assert_equal 0, raw.open_map('lobData').size
    end
  end

  def test_block_form_closes_readers_and_temporary_values_when_the_block_raises
    with_storage do |storage,raw|
      storage.close
      reader = nil
      owner = nil
      assert_raises(IOError) do
        M::LobStorage.open(raw) do |current|
          owner = current
          reader = current.open(current.create_blob(StringIO.new('x' * 300000)))
          raise IOError, 'caller failed'
        end
      end
      assert owner.closed?
      assert reader.closed?
      assert_equal 0, raw.open_map('lobData').size
      assert_equal 0, raw.open_map('tempLobMap').size
      refute raw.closed?
    end
  end

  def test_concurrent_creations_allocate_distinct_references
    with_storage do |storage,_raw|
      threads = 4.times.map do |index|
        Thread.new do
          10.times.map { storage.create_blob(StringIO.new(index.to_s * 1000)) }
        end
      end
      values = threads.flat_map(&:value)
      assert_equal 40, values.map { it.data.lob_id }.uniq.size
      values.each_with_index do |value,index|
        storage.open(value) { |reader| assert_equal (index / 10).to_s * 1000, reader.read }
      end
    end
  end

  def test_exhausted_lob_ids_reclaim_new_blocks_and_preserve_existing_data
    with_storage do |storage,raw|
      existing = storage.create_blob(StringIO.new('kept' * 1000))
      storage.instance_variable_set(:@next_lob_id,(1 << 63) - 1)
      last = storage.create_blob(StringIO.new('last' * 1000))
      assert_equal (1 << 63) - 1, last.data.lob_id
      blocks = raw.open_map('lobData').to_a
      assert_raises(RangeError) { storage.create_blob(StringIO.new('failed' * 100000)) }
      assert_raises(RangeError) { storage.copy_lob(existing,table_id: 7) }
      assert_equal blocks, raw.open_map('lobData').to_a
      storage.open(existing) { |reader| assert_equal 'kept' * 1000, reader.read }
      storage.open(last) { |reader| assert_equal 'last' * 1000, reader.read }
    end
  end
end

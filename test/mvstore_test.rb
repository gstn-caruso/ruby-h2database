# frozen_string_literal: true

require_relative "test_helper"
require "h2/mvstore"
require "tmpdir"
require "fileutils"

class MVStoreFormatTest < Minitest::Test
  M = H2::MVStore
  FIXTURES = File.expand_path("fixtures/mvstore", __dir__)
  WORDS = 'words, "Unicode"'

  def test_java_primitive_vectors
    File.foreach(File.join(FIXTURES, "primitives.tsv")) do |line|
      kind, value, encoded, decoded = line.chomp.split("\t", -1)
      case kind
      when "I", "L"
        buffer = M::Buffer.new
        kind == "I" ? M::DataUtils.write_var_int(buffer, value.to_i) : M::DataUtils.write_var_long(buffer, value.to_i)
        assert_equal encoded, buffer.data.unpack1("H*"), line
        reader = M::Buffer.new([encoded].pack("H*"))
        actual = kind == "I" ? M::DataUtils.read_var_int(reader) : M::DataUtils.read_var_long(reader)
        assert_equal value.to_i, actual, line
        assert_equal 0, reader.remaining
      when "S"
        units = [value].pack("H*").force_encoding(Encoding::UTF_16BE)
        text = units.valid_encoding? ? units.encode(Encoding::UTF_8) : units
        buffer = M::Buffer.new
        M::Codecs::STRING.write(buffer, text)
        assert_equal encoded, buffer.data.unpack1("H*"), line
        actual = M::Codecs::STRING.read(M::Buffer.new([encoded].pack("H*")))
        assert_equal value, M::Codecs::STRING.units(actual).pack("n*").unpack1("H*"), line
      when "P"
        assert_equal encoded.to_i, M::DataUtils.encode_length(value.to_i)
        assert_equal decoded.to_i, M::DataUtils.decode_length(encoded.to_i)
      when "F"
        assert_equal encoded.to_i, M::DataUtils.fletcher32([value].pack("H*"))
      else flunk "Unknown Java vector #{kind}"
      end
    end
  end

  def test_page_positions_cover_all_chunk_and_offset_bits
    [1, 0x3ff_ffff].each do |chunk|
      [0, 128, 0x7fff_ffff].each do |offset|
        [0, 1].each do |type|
          position = M::DataUtils.page_position(chunk, offset, 33, type)
          assert_equal chunk, M::DataUtils.chunk_id(position)
          assert_equal offset, M::DataUtils.page_offset(position)
          assert_equal type, M::DataUtils.page_type(position)
          assert_equal 48, M::DataUtils.page_max_length(position)
        end
      end
    end
  end

  def test_metadata_escaping_and_checksums
    values = {"name" => 'words, "Unicode"', "empty" => "", "backslash" => "a\\b", "number" => 255}
    text = M::DataUtils.dump_map(values)
    assert_equal values.transform_values { it.is_a?(Integer) ? it.to_s(16) : it }, M::DataUtils.parse_map(text)
    header = M::DataUtils.checksummed_map({"H" => 2, "format" => 3}, size: 4096)
    assert_equal({"H" => "2", "format" => "3"}, M::DataUtils.parse_checksummed_map(header))
    damaged = header.dup
    damaged.setbyte(0, damaged.getbyte(0) ^ 1)
    assert_nil M::DataUtils.parse_checksummed_map(damaged)
  end

  def test_java_files_read_plain_lzf_and_deflate_trees
    3.times do |compression|
      M::Store.open(File.join(FIXTURES, "java-#{compression}.mv"), read_only: true) do |store|
        assert_includes store.map_names, WORDS
        words = store.open_map(WORDS)
        assert_equal "empty", words[""]
        assert_equal "árbol", words["café"]
        assert_equal "漢字", words["中文"]
        assert_equal "😀", words["😀"]
        assert_equal "zero\0", words["nul\0key"]
        assert_nil words["key-000"]
        assert_equal "updated before close", words["key-001"]
        assert_equal "second commit", words["later"]
        assert_equal "abc" * 2000, words["repeat"]
        assert_equal 136, words.size
        keys = words.map(&:first)
        assert_operator keys.index("😀"), :<, keys.index("\uFFFF")
        longs = store.open_map("longs", key_type: :long, value_type: :long)
        assert_equal 9_223_372_036_854_775_807, longs[-9_223_372_036_854_775_808]
        assert_equal(-9_223_372_036_854_775_808, longs[9_223_372_036_854_775_807])
        assert_operator store.chunks.size, :>=, 2
      end
    end
  end

  def test_sql_database_metadata_is_read_from_the_real_mvstore_file
    M::Store.open(File.join(FIXTURES, "java-sql.mv.db"), read_only: true) do |store|
      assert store.map_names.any? { it.start_with?("table.") }
      assert store.map_names.any? { it.start_with?("index.") }
      assert_equal 3, store.header.fetch("format").to_i(16)
    end
  end

  def test_native_commits_reopen_multiple_maps_and_rollback
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "native.mv")
      M::Store.open(path, keys_per_page: 8) do |store|
        words = store.open_map(WORDS)
        130.times { words["key-%03d" % it] = "value #{it}" }
        longs = store.open_map("longs", key_type: :long, value_type: :long)
        longs[-7] = 42
        assert_equal 1, store.commit
        words["key-000"] = "changed"
        words.delete("key-001")
        store.rollback
        assert_equal "value 0", words["key-000"]
        assert_equal "value 1", words["key-001"]
        words["new"] = "persisted"
        assert_equal 2, store.commit
      end
      M::Store.open(path, read_only: true) do |store|
        assert_equal "persisted", store.open_map(WORDS)["new"]
        assert_equal 42, store.open_map("longs", key_type: :long, value_type: :long)[-7]
        assert_equal 2, store.version
      end
    end
  end

  def test_empty_maps_rollback_and_copied_inputs
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "empty.mv")
      M::Store.open(path) do |store|
        empty = store.open_map("empty")
        store.commit
        removed = store.open_map("rolled back")
        removed["key"] = "discarded"
        store.rollback
        assert_equal 4, assert_raises(M::Error) { removed["key"] }.code
        assert_equal ["empty"], store.map_names
        key, value = +"key", +"value"
        empty[key] = value
        key.replace("changed")
        value.replace("changed")
        assert_equal "value", empty["key"]
        assert empty["key"].frozen?
        empty.delete("key")
      end
      M::Store.open(path, read_only: true) do |store|
        assert_equal ["empty"], store.map_names
        assert_equal({}, store.open_map("empty").to_h)
      end
    end
  end

  def test_failed_chunk_write_keeps_the_previous_commit
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "partial.mv")
      store = M::Store.open(path)
      map = store.open_map("data")
      map["key"] = "committed"
      store.commit
      storage = store.instance_variable_get(:@storage)
      storage.define_singleton_method(:write_at) do |offset, bytes|
        super(offset, bytes.byteslice(0, bytes.bytesize / 2))
        raise M::Error.new(2, "Injected partial chunk write")
      end
      map["key"] = "incomplete"
      assert_equal 2, assert_raises(M::Error) { store.commit }.code
      assert store.closed?
      M::Store.open(path) do |recovered|
        assert_equal 1, recovered.version
        assert_equal "committed", recovered.open_map("data")["key"]
        recovered.open_map("data")["key"] = "after recovery"
      end
      M::Store.open(path, read_only: true) do |recovered|
        assert_equal 2, recovered.version
        assert_equal "after recovery", recovered.open_map("data")["key"]
      end
    end
  end

  def test_failed_header_write_recovers_the_synced_chunk
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "header.mv")
      store = M::Store.open(path)
      map = store.open_map("data")
      map["key"] = "first"
      store.commit
      storage = store.instance_variable_get(:@storage)
      storage.define_singleton_method(:write_at) do |offset, bytes|
        raise M::Error.new(2, "Injected header write failure") if offset < 8192

        super(offset, bytes)
      end
      map["key"] = "synced before header failure"
      assert_equal 2, assert_raises(M::Error) { store.commit }.code
      assert store.closed?
      M::Store.open(path, read_only: true) do |recovered|
        assert_equal 2, recovered.version
        assert_equal "synced before header failure", recovered.open_map("data")["key"]
      end
    end
  end

  def test_future_write_format_is_read_only_and_never_modified
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "future.mv")
      bytes = File.binread(File.join(FIXTURES, "java-0.mv"))
      header = M::DataUtils.parse_checksummed_map(bytes.byteslice(0, 4096))
      bytes[0, 8192] = M::DataUtils.checksummed_map(header.merge("format" => 4, "formatRead" => 3), size: 4096) * 2
      File.binwrite(path, bytes)
      M::Store.open(path, read_only: true) { assert_equal "value", it.open_map(WORDS)["ascii"] }
      assert_equal 5, assert_raises(M::Error) { M::Store.open(path) }.code
      assert_equal bytes, File.binread(path)
    end
  end

  def test_utf16_input_preserves_unpaired_surrogates_and_rejects_partial_units
    surrogate = [0xd800].pack("n").force_encoding(Encoding::UTF_16BE)
    assert_equal surrogate, M::Codecs::STRING.copy(surrogate)
    [Encoding::UTF_16BE, Encoding::UTF_16LE].each do |encoding|
      incomplete = "x".dup.force_encoding(encoding)
      assert_raises(ArgumentError) { M::Codecs::STRING.copy(incomplete) }
    end
  end

  def test_native_compressed_large_pages_and_unicode_order
    [:none, :fast, :high].each do |compression|
      Dir.mktmpdir("ruby-mvstore-") do |directory|
        path = File.join(directory, "native.mv")
        M::Store.open(path, compression: compression) do |store|
          map = store.open_map("data")
          map["huge"] = "abc😀" * 190_000
          map["\uFFFF"] = "bmp"
          map["😀"] = "supplementary"
        end
        M::Store.open(path, read_only: true) do |store|
          map = store.open_map("data")
          assert_equal "abc😀" * 190_000, map["huge"]
          assert_equal ["huge", "😀", "\uFFFF"], map.map(&:first)
        end
      end
    end
  end

  def test_read_only_and_closed_stores_reject_mutation
    store = M::Store.open(File.join(FIXTURES, "java-0.mv"), read_only: true)
    map = store.open_map(WORDS)
    assert_raises(M::Error) { map["bad"] = "write" }
    assert_raises(M::Error) { store.open_map("missing") }
    store.close
    assert_equal 4, assert_raises(M::Error) { map["ascii"] }.code
    assert store.closed?
    store.close
  end

  def test_locks_are_held_per_open_file_description
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "locked.mv")
      M::Store.open(path) do
        assert_equal 7, assert_raises(M::Error) { M::Store.open(path) }.code
      end
      a = M::Store.open(path, read_only: true)
      b = M::Store.open(path, read_only: true)
      a.close
      assert_equal 7, assert_raises(M::Error) { M::Store.open(path) }.code
      b.close
      M::Store.open(path) { assert true }
    end
  end

  def test_header_redundancy_and_torn_append_recovery
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "recover.mv")
      FileUtils.cp(File.join(FIXTURES, "java-0.mv"), path)
      File.open(path, "r+b") { it.write("broken header") }
      M::Store.open(path, read_only: true) { assert_equal "value", it.open_map(WORDS)["ascii"] }
      File.open(path, "ab") { it.write("chunk:ffffff,len:100\n".ljust(4096, "\0")) }
      M::Store.open(path, read_only: true) { assert_equal "value", it.open_map(WORDS)["ascii"] }
      File.open(path, "r+b") { it.seek(4096); it.write("broken header") }
      assert_equal 6, assert_raises(M::Error) { M::Store.open(path, read_only: true) }.code
    end
  end

  def test_page_corruption_and_truncated_primitives_fail_explicitly
    assert_equal 6, assert_raises(M::Error) { M::DataUtils.read_var_long(M::Buffer.new("\x80".b)) }.code
    assert_equal 6, assert_raises(M::Error) { M::Codecs::STRING.read(M::Buffer.new("\x05a".b)) }.code
    Dir.mktmpdir("ruby-mvstore-") do |directory|
      path = File.join(directory, "corrupt.mv")
      FileUtils.cp(File.join(FIXTURES, "java-0.mv"), path)
      store = M::Store.open(path, read_only: true)
      position = store.layout.fetch("root.2").to_i(16)
      chunk = store.chunks.fetch(M::DataUtils.chunk_id(position))
      offset = chunk.block * 4096 + M::DataUtils.page_offset(position) + 4
      store.close
      File.open(path, "r+b") { |file| file.seek(offset); byte = file.read(1).getbyte(0); file.seek(offset); file.write((byte ^ 1).chr) }
      assert_equal 6, assert_raises(M::Error) { M::Store.open(path, read_only: true) { it.open_map(WORDS).to_h } }.code
    end
  end
end

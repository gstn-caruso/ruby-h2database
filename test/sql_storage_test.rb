# frozen_string_literal: true

require_relative "test_helper"
require "h2/mvstore"
require "tmpdir"

class SQLStorageTest < Minitest::Test
  M = H2::MVStore
  FIXTURES = File.expand_path("fixtures/mvstore", __dir__)

  def test_java_sql_value_vectors_reencode_identically
    count = 0
    File.foreach(File.join(FIXTURES, "sql-values.tsv")) do |line|
      label, hex = line.chomp.split("\t")
      buffer = M::Buffer.new([hex].pack("H*"))
      value = M::Codecs::VALUE.read(buffer)
      assert_equal 0, buffer.remaining, label
      output = M::Buffer.new
      M::Codecs::VALUE.write(output, value)
      assert_equal hex, output.data.unpack1("H*"), "Java value #{label}: #{value.inspect}"
      count += 1
    end
    assert_operator count, :>, 140
  end

  def test_java_codec_descriptors_reencode_identically
    lines = File.readlines(File.join(FIXTURES, "sql-codecs.tsv"))
    assert_equal 13, lines.length
    lines.each do |line|
      label, hex = line.chomp.split("\t")
      buffer = M::Buffer.new([hex].pack("H*"))
      codec = M::Codecs::META.read(buffer)
      assert_equal 0, buffer.remaining, label
      output = M::Buffer.new
      M::Codecs::META.write(output, codec)
      assert_equal hex, output.data.unpack1("H*"), label
    end
  end

  def test_decimal_scale_and_integer_type_identity_are_preserved
    value = M::Value.new(:numeric, M::Decimal.new(1200, 3))
    assert_equal BigDecimal("1.200"), value.to_ruby
    assert_equal 3, value.data.scale
    assert_equal :integer, decode("21").type
    assert_equal :bigint, decode("31").type
    assert_equal :tinyint, decode("0201").type
    assert_equal :smallint, decode("030001").type
    assert_equal(-2_147_483_648, decode("428080808008").data)
    assert_equal(-9_223_372_036_854_775_808, decode("4380808080808080808001").data)
  end

  def test_values_copy_strings_and_nested_containers
    text = +"value"
    value = M::Value.new(:varchar, text)
    fields = [value]
    row = M::Value.new(:row, fields)
    text.replace("changed")
    fields.clear
    assert_equal ["value"], row.to_ruby
    assert row.data.frozen?
    assert row.data.first.data.frozen?
  end

  def test_sql_value_payloads_retain_decimal_temporal_collection_and_lob_information
    values = File.readlines(File.join(FIXTURES, "sql-values.tsv")).map { decode(it.chomp.split("\t").last) }
    assert values.include?(M::Value.new(:numeric, M::Decimal.new(12345678901234567890123456789012300, 5)))
    assert values.include?(M::Value.new(:varchar, "café 中文 😀"))
    assert values.include?(M::Value.new(:timestamp_tz, [(2026 << 9) | (10 << 5) | 23, (12 * 3600 + 34 * 60 + 56) * 1_000_000_000 + 123456789, 1]))
    assert values.include?(M::Value.new(:blob, M::LobReference.new(7, 999, 123456, nil)))
    assert values.include?(M::Value.new(:clob, M::InlineClob.new("café 😀", 7)))
    array = values.find { it.type == :array }
    assert_equal [1, nil, 3], array.to_ruby
    row = values.find { it.type == :row }
    assert_equal [1, "nested", [true]], row.to_ruby
    assert_equal :nan, values.find { it.type == :decfloat && it.data == :nan }.data
  end

  def test_typed_maps_commit_and_rollback_without_losing_value_types
    Dir.mktmpdir("typed-mvstore-") do |directory|
      path = File.join(directory, "values.mv")
      M::Store.open(path, keys_per_page: 2) do |store|
        map = store.open_map("values", key_type: :long, value_type: :value)
        assert_same map, store.open_map("values")
        map[1] = M::Value.new(:numeric, M::Decimal.new(12500, 4))
        map[2] = M::Value.new(:row, [M::Value.new(:integer, 3), M::Value.new(:varchar, "😀")])
        store.commit
        map[1] = M::Value.new(:null, nil)
        store.rollback
        assert_equal M::Decimal.new(12500, 4), map[1].data
      end
      M::Store.open(path, read_only: true) do |store|
        map = store.open_map("values", key_type: :long, value_type: :value)
        assert_equal 4, map[1].data.scale
        assert_equal [3, "😀"], map[2].to_ruby
      end
    end
  end

  def test_map_keys_use_h2_comparison_instead_of_ruby_object_equality
    Dir.mktmpdir("typed-map-keys-") do |directory|
      M::Store.open(File.join(directory, "keys.mv"), keys_per_page: 2) do |store|
        map = store.open_map("numeric", key_type: :value)
        first = M::Value.new(:numeric, M::Decimal.new(120, 2))
        equivalent = M::Value.new(:numeric, M::Decimal.new(1200, 3))
        map[first] = "original"
        assert_equal "original", map[equivalent]
        map[equivalent] = "replacement"
        assert_equal 1, map.size
        assert_equal first, map.first.first
        assert_equal "replacement", map.delete(equivalent)
        assert_equal 0, map.size
        row_type = M::Codecs::RowType.new(column_count: 2, sort_types: [0], indexes: [1], store_keys: true)
        index = store.open_map("index", key_type: row_type)
        key = M::SearchRow.new(7, [nil, M::Value.new(:varchar, "key")])
        index[key] = "entry"
        alias_key = key.with(values: [M::Value.new(:integer, 99), key.values[1]])
        assert_equal "entry", index[alias_key]
        index[alias_key] = "updated"
        assert_equal 1, index.size
        store.commit
      end
    end
  end

  def test_null_codec_pages_can_have_a_single_key_without_payload_bytes
    null = M::Codecs::MetaType::STATELESS.fetch("org.h2.mvstore.db.NullValueDataType")
    Dir.mktmpdir("null-mvstore-") do |directory|
      path = File.join(directory, "null.mv")
      value = M::Value.new(:null, nil)
      M::Store.open(path) { it.open_map("null", key_type: null, value_type: null)[value] = value }
      M::Store.open(path, read_only: true) do |store|
        map = store.open_map("null", key_type: null, value_type: null)
        assert_equal 1, map.size
        assert_equal value, map[value]
      end
    end
  end

  def test_corrupt_values_fail_explicitly
    ["ff", "060001", "118080808008", "1b03", "8740", "1ae000", "0fffffffff0f"].each do |hex|
      assert_equal 6, assert_raises(M::Error, hex) { decode(hex) }.code, hex
    end
  end

  def test_real_sql_table_and_index_rows_resolve_the_registered_codecs
    M::Store.open(File.join(FIXTURES, "java-sql.mv.db"), read_only: true) do |store|
      rows = store.open_map("table.3")
      assert_instance_of M::Codecs::VersionedType, rows.value_type
      assert_equal M::Codecs::LONG, rows.key_type
      assert_equal [1, "native storage reference"], rows[1].current.values.map(&:to_ruby)
      assert rows[1].committed?
      index = store.open_map("index.6")
      assert_equal [["native storage reference", 1]], index.map { |key, _value| [key.values[1].to_ruby, key.key] }
      catalog = store.open_map("table.0")
      assert catalog.any? { |_key, value| value.current.values.any? { it.type == :varchar && it.data.start_with?("CREATE CACHED TABLE") } }
    end
  end

  def test_versioned_value_fast_slow_and_legacy_encodings
    codec = M::Codecs::VersionedType.new(M::Codecs::VALUE)
    value = M::Value.new(:integer, 1)
    fast = [M::VersionedValue.new(current: value), M::VersionedValue.new(current: M::Value.new(:null, nil))]
    buffer = M::Buffer.new
    codec.write_many(buffer, fast)
    assert_equal "002100", buffer.data.unpack1("H*")
    assert_equal fast, codec.read_many(M::Buffer.new(buffer.data), 2)
    slow = [M::VersionedValue.new(current: value, committed: M::Value.new(:integer, 2), operation_id: (1 << 40) + 3, entry_id: 99), M::VersionedValue.new(current: nil, operation_id: 4)]
    buffer = M::Buffer.new
    codec.write_many(buffer, slow)
    assert_equal 1, buffer.data.getbyte(0)
    assert_equal slow, codec.read_many(M::Buffer.new(buffer.data), 2)
    legacy = M::Buffer.new
    M::DataUtils.write_var_long(legacy, (1 << 40) + 3)
    legacy.put_byte(3).put_byte(33).put_byte(34)
    assert_equal slow.first.with(entry_id: -1), codec.read(M::Buffer.new(legacy.data))
    assert_equal 6, assert_raises(M::Error) { codec.read_many(M::Buffer.new("\x02".b), 1) }.code
  end

  def test_java_uncommitted_rows_keep_both_versions_and_entry_ids
    M::Store.open(File.join(FIXTURES, "java-pending.mv"), read_only: true) do |store|
      map = store.open_map("pending")
      assert_equal [1, 2, 3], map.map(&:first)
      assert_equal 20, map[1].current.data
      assert_equal 10, map[1].committed.data
      assert_nil map[2].current
      assert_equal 11, map[2].committed.data
      assert_equal "inserted", map[3].current.data
      assert_nil map[3].committed
      assert map.all? { |_key, value| !value.committed? && value.entry_id >= 0 }
    end
  end

  def test_metadata_rejects_unknown_factories_and_wrong_explicit_codecs
    buffer = M::Buffer.new
    M::Codecs::STRING.write(buffer, "unknown.UnsafeFactory")
    assert_equal 5, assert_raises(M::Error) { M::Codecs::META.read(M::Buffer.new(buffer.data)) }.code
    M::Store.open(File.join(FIXTURES, "java-sql.mv.db"), read_only: true) do |store|
      assert_equal 5, assert_raises(M::Error) { store.open_map("table.3", value_type: :string) }.code
      registry = store.open_map("_", value_type: :meta)
      registry.each do |_key, type|
        encoded = M::Buffer.new
        M::Codecs::META.write(encoded, type)
        assert_equal type, M::Codecs::META.read(M::Buffer.new(encoded.data))
      end
    end
  end

  private

  def decode(hex)
    M::Codecs::VALUE.read(M::Buffer.new([hex].pack("H*")))
  end
end

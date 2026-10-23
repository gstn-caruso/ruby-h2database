# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class BinaryUuidTest < DatabaseTest
  def test_hex_literals_preserve_bytes_and_join_adjacent_parts
    result = execute("SELECT X'00 ff' 'c3a9' AS b, X'' AS empty")
    assert_equal [["\x00\xff\xc3\xa9".b, "".b]], result.rows
    assert_equal ["VARBINARY", "VARBINARY"], result.types.map(&:name)
    assert_equal Encoding::BINARY, result.rows.first.first.encoding
    assert_predicate result.rows.first.first, :frozen?
    assert_sql_error 90003, "VALUES X'1'"
    assert_sql_error 90004, "VALUES X'gg'"
    assert_sql_error 42000, "VALUES X'ab''cd'"
  end

  def test_binary_assignment_padding_casts_and_atomic_length_failures
    execute("CREATE TABLE t(id INT PRIMARY KEY, b BINARY(3), v BINARY VARYING(3))")
    execute("INSERT INTO t VALUES(1,X'ff',X'00ff')")
    assert_equal [[1, "\xff\x00\x00".b, "\x00\xff".b]], rows("TABLE t")
    assert_equal [["\x01\x02".b, "\x01\x02".b]], rows("SELECT CAST(X'010203' AS BINARY(2)), CAST(X'010203' AS VARBINARY(2))")
    assert_sql_error 22001, "INSERT INTO t VALUES(2,X'01',X'01020304'),(3,X'02',NULL)"
    assert_sql_error 22001, "UPDATE t SET b=X'01020300'"
    assert_equal 1, rows("TABLE t").length
    assert_sql_error 90008, "CREATE TABLE bad(v BINARY(0))"
    assert_sql_error 90150, "CREATE TABLE bad(v VARBINARY(1000000001))"
  end

  def test_binary_parameters_are_copied_and_text_is_encoded_as_utf8
    execute("CREATE TABLE t(b VARBINARY, s VARCHAR)")
    bytes = "\x00\xff".b
    execute("INSERT INTO t VALUES(?,?)", bytes, "café")
    bytes.replace("changed")
    assert_equal [["\x00\xff".b, "café"]], rows("TABLE t")
    assert_equal [["é😀".b, "é😀"]], rows("SELECT CAST('é😀' AS VARBINARY), CAST(X'c3a9f09f9880' AS VARCHAR)")
    assert_equal [["\uFFFD", "\uFFFD", "\uFFFD("]], rows("SELECT CAST(X'eda080' AS VARCHAR), CAST(X'eda0' AS VARCHAR), CAST(X'f09f28' AS VARCHAR)")
  end

  def test_binary_comparisons_membership_grouping_and_concatenation
    execute("CREATE TABLE t(v VARBINARY UNIQUE)")
    execute("INSERT INTO t VALUES(X'ff'),(X'00'),(X'0000'),(NULL)")
    assert_equal [[nil], ["\x00".b], ["\x00\x00".b], ["\xff".b]], rows("TABLE t ORDER BY v")
    assert_sql_error 23505, "INSERT INTO t VALUES(X'00')"
    assert_equal [[true, true, nil, "\x00\xff".b, "AB"]], rows("SELECT X'00'<X'ff', X'ff' IN(X'00',X'ff'), X'02' IN(X'00',NULL), X'00'||X'ff', X'41'||'B'")
    assert_sql_error 90110, "SELECT X'41'='A'"
    assert_sql_error 90110, "SELECT X'01'=1"
    assert_sql_error 50100, "SELECT X'01'+X'02'"
    execute("CREATE TABLE empty_values(v VARBINARY)")
    assert_sql_error 50100, "SELECT v+X'02' FROM empty_values"
    assert_sql_error 90110, "SELECT v IN('A') FROM empty_values"
    assert_sql_error 90015, "SELECT SUM(v) FROM empty_values"
    assert_equal [[4, "\x00".b, "\xff".b]], rows("SELECT COUNT(DISTINCT v)+1, MIN(v), MAX(v) FROM t")
    assert_equal [["A".b]], rows("SELECT COALESCE(CAST(NULL AS VARBINARY),'A')")
  end

  def test_binary_integer_casts_use_signed_big_endian_widths
    assert_equal [["\xff".b, "\xff\xfe".b, "\x00\x00\x00\x01".b, "\xff".b * 8]], rows("SELECT CAST(CAST(-1 AS TINYINT) AS VARBINARY), CAST(CAST(-2 AS SMALLINT) AS VARBINARY), CAST(1 AS VARBINARY), CAST(CAST(-1 AS BIGINT) AS VARBINARY)")
    assert_equal [[-1, -2, 1, -1]], rows("SELECT CAST(X'ff' AS TINYINT), CAST(X'fffe' AS SMALLINT), CAST(X'00000001' AS INT), CAST(X'ffffffffffffffff' AS BIGINT)")
    assert_sql_error 22018, "SELECT CAST(X'01' AS INT)"
    assert_sql_error 22018, "SELECT CAST(X'31' AS NUMERIC)"
    assert_sql_error 22018, "SELECT CAST(TRUE AS VARBINARY)"
    execute("CREATE TABLE numbers(v VARBINARY DEFAULT CAST(-1 AS SMALLINT))")
    execute("INSERT INTO numbers DEFAULT VALUES")
    execute("INSERT INTO numbers VALUES(CAST(-2 AS TINYINT))")
    execute("INSERT INTO numbers SELECT CAST(-3 AS BIGINT)")
    assert_equal [["\xff\xff".b], ["\xfe".b], ["\xff\xff\xff\xff\xff\xff\xff\xfd".b]], rows("TABLE numbers")
    execute("UPDATE numbers SET v=CAST(1 AS SMALLINT)")
    assert_equal [["\x00\x01".b]] * 3, rows("TABLE numbers")
  end

  def test_uuid_values_conversion_comparison_and_parameters
    value = H2::UUIDValue.parse("01234567-89AB-CDEF-0123-456789ABCDEF")
    assert_equal "01234567-89ab-cdef-0123-456789abcdef", value.to_s
    assert_equal ["0123456789abcdef0123456789abcdef"].pack("H*"), value.bytes
    assert_predicate value.bytes, :frozen?
    assert_equal [[value, value, value]], rows("SELECT UUID '01234567-89AB-CDEF-0123-456789ABCDEF', CAST(X'0123456789abcdef0123456789abcdef' AS UUID), ?", value)
    assert_equal [[true, true]], rows("SELECT UUID '00000000-0000-0000-9000-000000000000'>UUID '00000000-0000-0000-0000-000000000000', UUID '00000000-0000-0000-0000-000000000000'='00000000000000000000000000000000'")
    assert_sql_error 22018, "SELECT CAST('not a uuid' AS UUID)"
    assert_sql_error 22018, "SELECT CAST(X'00' AS UUID)"
    assert_sql_error 22018, "SELECT CAST(1 AS UUID)"
    error = assert_raises(H2::Error) { H2::UUIDValue.parse("\xff".b.force_encoding(Encoding::UTF_8)) }
    assert_equal 22018, error.code
  end

  def test_binary_and_uuid_persist_defaults_keys_and_row_values
    Dir.mktmpdir do |directory|
      path = File.join(directory, "typed")
      uuid = H2::UUIDValue.parse("01234567-89ab-cdef-0123-456789abcdef")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(u UUID PRIMARY KEY DEFAULT ?, b BINARY(3) DEFAULT X'00ff', v VARBINARY DEFAULT ?)", uuid, "\xff\x00".b)
        connection.execute("INSERT INTO t DEFAULT VALUES")
        connection.execute("CREATE TABLE r AS SELECT ROW(UUID '00000000-0000-0000-0000-000000000000',X'ff00') AS pair")
        connection.execute("CREATE TABLE empty AS SELECT X'' AS v")
        connection.execute("CREATE TABLE numeric_default(v VARBINARY DEFAULT CAST(-1 AS SMALLINT))")
      end
      H2.connect(path: path) do |connection|
        assert_equal [[uuid, "\x00\xff\x00".b, "\xff\x00".b]], connection.execute("TABLE t").rows
        assert_equal ["UUID", "BINARY", "VARBINARY"], connection.execute("TABLE t").types.map(&:name)
        assert_equal [[H2::RowValue.new([H2::UUIDValue.parse("0" * 32), "\xff\x00".b])]], connection.execute("TABLE r").rows
        assert_equal [["".b]], connection.execute("TABLE empty").rows
        connection.execute("INSERT INTO numeric_default DEFAULT VALUES")
        assert_equal [["\xff\xff".b]], connection.execute("TABLE numeric_default").rows
        error = assert_raises(H2::Error) { connection.execute("INSERT INTO t DEFAULT VALUES") }
        assert_equal 23505, error.code
      end
    end
  end

  def test_octet_bit_and_character_lengths_follow_value_types
    assert_equal [[2, 2, 2, 16, 36, 16, 3]], rows("SELECT LENGTH(X'c3a9'), CHAR_LENGTH(X'c3a9'), OCTET_LENGTH(X'c3a9'), BIT_LENGTH(X'c3a9'), LENGTH(UUID '00000000-0000-0000-0000-000000000000'), OCTET_LENGTH(UUID '00000000-0000-0000-0000-000000000000'), CHAR_LENGTH('😀a')")
  end

  def test_inline_values_source_resolves_aliases_and_outer_ordering
    assert_equal [["\xff".b], ["\x00".b]], rows("SELECT v FROM VALUES(X'00'),(X'ff') AS t(v) ORDER BY v DESC")
    execute("CREATE TABLE uuids(u UUID) AS (SELECT * FROM VALUES('00000000000000000000000000000000'),('ffffffffffffffffffffffffffffffff'))")
    assert_equal [[H2::UUIDValue.parse("0" * 32)], [H2::UUIDValue.parse("f" * 32)]], rows("TABLE uuids ORDER BY u")
  end
end

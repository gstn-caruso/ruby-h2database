# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class JsonTest < DatabaseTest
  def test_literals_normalize_json_without_losing_duplicate_keys_or_decimal_scale
    value = rows(%q{SELECT JSON ' {"a":1.00,"a":2,"nested":[true,null,"x"]} '}).first.first
    assert_equal %q{{"a":1.00,"a":2,"nested":[true,null,"x"]}}, value.to_s
    assert_equal :object, value.kind
    refute value.unique_keys?
    assert_predicate value.bytes, :frozen?
    assert_equal "JSON", execute("SELECT JSON 'null'").types.first.name
  end

  def test_casts_quote_strings_while_format_and_binary_inputs_parse_json
    result = rows(%q{SELECT CAST('true' AS JSON),'true' FORMAT JSON,CAST(X'74727565' AS JSON),NULL FORMAT JSON,JSON 'null'})
    assert_equal ['"true"', 'true', 'true', nil, 'null'], result.first.map { it&.to_s }
    assert_equal ['[1,null,2]', '"2000-01-01T12:34:56"'], rows("SELECT CAST(ARRAY[1,NULL,2] AS JSON),CAST(TIMESTAMP '2000-01-01 12:34:56' AS JSON)").first.map(&:to_s)
    assert_sql_error 22018, "SELECT 'bad' FORMAT JSON"
    assert_sql_error 22018, "SELECT CAST(ROW(1,2) AS JSON)"
  end

  def test_json_predicates_validate_shapes_nulls_and_nested_unique_keys
    assert_equal [[true, false, true, true, false, nil]], rows(%q{SELECT '{}' IS JSON OBJECT,'[]' IS JSON SCALAR,'1' IS JSON SCALAR,'bad' IS NOT JSON,1 IS JSON,NULL IS JSON})
    assert_equal [[false, true]], rows(%q{SELECT '{"x":[{"a":1,"a":2}]}' IS JSON WITH UNIQUE KEYS,'{"x":1,"y":{"x":2}}' IS JSON WITH UNIQUE KEYS})
    assert_equal [[1], [2]], rows(%q{SELECT CASE s WHEN IS JSON ARRAY THEN 1 ELSE 2 END FROM (VALUES ('[]'),('bad')) t(s)})
  end

  def test_json_constructors_preserve_order_duplicates_and_null_flags
    assert_equal '[1,"x",null,null]', rows(%q{SELECT JSON_ARRAY(1,'x',NULL,JSON 'null' NULL ON NULL)}).first.first.to_s
    assert_equal '[1]', rows(%q{SELECT JSON_ARRAY(NULL,1,JSON 'null')}).first.first.to_s
    assert_equal '{"a":1,"a":2,"b":null}', rows(%q{SELECT JSON_OBJECT('a':1,KEY 'a' VALUE 2,'b':NULL)}).first.first.to_s
    assert_equal '{}', rows(%q{SELECT JSON_OBJECT('a':NULL,'a':JSON 'null' ABSENT ON NULL WITH UNIQUE KEYS)}).first.first.to_s
    assert_sql_error 90008, %q{SELECT JSON_OBJECT('a':1,'a':2 WITH UNIQUE KEYS)}
    assert_sql_error 90008, "SELECT JSON_OBJECT(NULL:1)"
    assert_equal '{"Infinity":1}', rows("SELECT JSON_OBJECT(CAST(1E999 AS DOUBLE):1)").first.first.to_s
  end

  def test_json_array_queries_indexing_and_unnest_keep_json_null_separate
    assert_equal '[1,2]', rows("SELECT JSON_ARRAY(SELECT x FROM SYSTEM_RANGE(1,2))").first.first.to_s
    assert_equal ['[3,4]', '3', nil, nil], rows(%q{SELECT JSON '[[1,2],[3,4]]'[2],JSON '[[1,2],[3,4]]'[2][1],JSON '[1]'[0],JSON '{}'[1]}).first.map { it&.to_s }
    assert_equal [['1', 1], ['null', 2], ['"x"', 3]], rows(%q{SELECT * FROM UNNEST(JSON '[1,null,"x"]') WITH ORDINALITY}).map { |v,n| [v.to_s,n] }
    assert_equal [], rows("SELECT * FROM UNNEST(JSON 'null')")
    assert_equal ['JSON', 'INTEGER'], execute("SELECT * FROM UNNEST(JSON '[]') WITH ORDINALITY").types.map(&:name)
  end

  def test_json_precision_bindings_comparisons_and_key_identity
    execute("CREATE TABLE t(j JSON(7) PRIMARY KEY)")
    execute("INSERT INTO t VALUES(?)", H2::JsonValue.parse('{"a":1}'))
    assert_equal [[true, false]], rows(%q{SELECT JSON '1'=JSON '1',JSON '1'=JSON '1.0'})
    assert_sql_error 23505, %q{INSERT INTO t VALUES(JSON ' {"a":1} ')}
    assert_sql_error 22001, "SELECT CAST(JSON 'null' AS JSON(3))"
    assert_sql_error 90008, "CREATE TABLE invalid_json(j JSON(0))"
    assert_sql_error 90150, "CREATE TABLE invalid_json(j JSON(1000000001))"
    assert_equal [[1]], rows(%q{SELECT COUNT(*) FROM t WHERE j=JSON '{"a":1}'})
  end

  def test_native_parser_handles_numbers_unicode_encodings_and_deep_documents
    assert_equal '[1,1.00,1E9,1E-9]', H2::JsonValue.parse('[001,1.00,1e+9,1e-9]').to_s
    assert_equal '"😀"', H2::JsonValue.parse('"\ud83d\ude00"').to_s
    assert_equal '[1]', H2::JsonValue.parse('[1]'.encode('UTF-16LE').b).to_s
    assert_equal '[1]', H2::JsonValue.parse('[1]'.encode('UTF-32BE').b).to_s
    assert_equal '"😀"', H2::JsonValue.parse(['22eda0bdedb88022'].pack('H*')).to_s
    assert_equal '"\u0001"', H2::JsonValue.parse('"\u+001"').to_s
    source = '[' * 2_000 + '0' + ']' * 2_000
    assert_equal source, H2::JsonValue.parse(source).to_s
    assert_raises(H2::Error) { H2::JsonValue.parse('"\ud800"') }
  end

  def test_json_text_casts_preserve_utf16_units_and_limits
    value = H2::JsonValue.parse('"😀"')
    result = execute("SELECT CAST(? AS VARCHAR(3)),CAST(? AS CHAR(2))", value, value)
    assert_equal ['0022d83dde00', '0022d83d'], result.rows.first.map { H2::CharacterString.sort_key(it).unpack1('H*') }
    assert_equal [3,2], result.types.map(&:precision)
    assert_sql_error 22001, "CREATE TABLE json_short(j JSON(1)) AS VALUES JSON 'null'"
    assert_sql_error 90053, "SELECT JSON_ARRAY((VALUES 1,2)) AS j WHERE FALSE"
  end

  def test_json_numbers_retain_the_minimum_signed_32bit_scale
    assert_equal '1E2147483648', H2::JsonValue.parse('1e2147483648').to_s
    assert_equal [[true, true, false]], rows("SELECT '1e2147483648' IS JSON SCALAR,'1e2147483648' IS JSON WITH UNIQUE KEYS,'1e2147483648' IS JSON ARRAY")
    assert_sql_error 22018, "SELECT '1e2147483649' FORMAT JSON"
    assert_sql_error 22018, "SELECT '1e-2147483648' FORMAT JSON"
  end

  def test_decfloat_conversion_keeps_precision_rounding_and_json_exponents
    result = execute("SELECT CAST(CAST('1.2300e100' AS DECFLOAT(3)) AS JSON),CAST(CAST('9.999' AS DECFLOAT(3)) AS JSON)")
    assert_equal ['1.23E100', '1E1'], result.rows.first.map(&:to_s)
    assert_sql_error 22018, "SELECT CAST(CAST('-Infinity' AS DECFLOAT) AS JSON)"
    assert_sql_error 22018, "SELECT CAST(X'31' AS DECFLOAT)"
    result = execute("SELECT CAST('1e100' AS DECFLOAT(12))")
    assert_equal ['DECFLOAT', 12, 0], [result.types.first.name, result.types.first.precision, result.types.first.scale]
    assert_equal '1E+100', result.rows.first.first.to_s
  end

  def test_json_values_and_dynamic_defaults_reopen_with_native_storage
    Dir.mktmpdir("h2-json") do |directory|
      path = File.join(directory, "db")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES(1),(2)")
        connection.execute("CREATE TABLE saved(j JSON PRIMARY KEY,a JSON DEFAULT JSON_ARRAY(SELECT v FROM source ORDER BY v DESC))")
        connection.execute("CREATE TABLE limited(j JSON(3))")
        connection.execute("INSERT INTO saved(j) VALUES(?)", H2::JsonValue.parse('{"a":1,"a":2}'))
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO source VALUES(3)")
        connection.execute("INSERT INTO saved(j) VALUES(JSON 'null')")
        assert_equal [['null', '[3,2,1]'], ['{"a":1,"a":2}', '[2,1]']], connection.execute("TABLE saved ORDER BY j").rows.map { it.map(&:to_s) }
        error = assert_raises(H2::Error) { connection.execute("INSERT INTO limited VALUES(JSON 'null')") }
        assert_equal 22001, error.code
      end
    end
  end
end

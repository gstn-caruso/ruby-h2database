# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class QuantifiedComparisonsTest < DatabaseTest
  def test_array_quantifiers_handle_empty_null_and_unknown_results
    assert_equal [[true, false, nil, nil]], rows("SELECT 1=ANY(ARRAY[1,NULL]),1=ALL(ARRAY[1,2]),3=ANY(ARRAY[1,NULL]),1=ALL(ARRAY[1,NULL])")
    assert_equal [[false, true, nil, nil]], rows("SELECT NULL=ANY(ARRAY[]),NULL=ALL(ARRAY[]),1=ANY(NULL),1=ALL(NULL)")
    assert_equal [[true, true, false]], rows("SELECT 2>SOME(ARRAY[1,3]),2>=ALL(ARRAY[1,2]),2<>ALL(ARRAY[1,2])")
  end

  def test_array_quantifiers_accept_scalars_rows_and_null_safe_operators
    assert_equal [[true, false, true]], rows("SELECT 1=ANY(1),1=ALL(2),1=ANY(ROW(1))")
    assert_sql_error 21002, "SELECT 2=ANY(ROW(1,2))"
    assert_sql_error 22018, "SELECT ROW(1)=ANY(1)"
    assert_equal [[true]], rows("SELECT ROW(1,2)=ANY(ROW(1,2))")
    assert_equal [[true, false, true]], rows("SELECT NULL IS NOT DISTINCT FROM ANY(ARRAY[1,NULL]),NULL IS DISTINCT FROM ALL(ARRAY[1,NULL]),NULL IS DISTINCT FROM ALL(ARRAY[])")
    assert_equal [[nil, true]], rows("SELECT ARRAY[1,NULL]=ANY(ARRAY[ARRAY[1,2]]),ARRAY[1,NULL] IS NOT DISTINCT FROM ANY(ARRAY[ARRAY[1,NULL]])")
  end

  def test_array_comparisons_are_lazy_and_do_not_validate_incompatible_empty_arrays
    assert_equal [[false, true]], rows("SELECT DATE '2000-01-01'=ANY(CAST(ARRAY[] AS INT ARRAY)),DATE '2000-01-01'=ALL(CAST(ARRAY[] AS INT ARRAY))")
    assert_equal [[true]], rows("SELECT 1=ANY(ARRAY['1','bad'])")
    assert_sql_error 22018, "SELECT 2=ANY(ARRAY['1','bad'])"
    assert_sql_error 22018, "SELECT DATE '2000-01-01'=ANY(ARRAY[1])"
    assert_equal [[false]], rows("SELECT ARRAY[1,2]=ANY(ARRAY[ARRAY['0','bad']])")
  end

  def test_query_quantifiers_handle_rows_correlations_and_preparation_errors
    assert_equal [[true, false, true, nil]], rows("SELECT 2>ANY(VALUES 1,3),2>ALL(VALUES 1,3),NULL=ALL(SELECT 1 WHERE FALSE),2=ANY(VALUES 1,NULL)")
    assert_equal [[true, true]], rows("SELECT ROW(1,2)=ANY(VALUES (1,2),(2,3)),ROW(2,3)>ALL(VALUES (1,2),(1,3))")
    assert_equal [[1, false], [2, true], [3, true]], rows("SELECT x,x>ANY(SELECT v FROM (VALUES 1,2) t(v) WHERE v<x) FROM SYSTEM_RANGE(1,3) ORDER BY x")
    assert_sql_error 90110, "SELECT DATE '2000-01-01'=ANY(SELECT 1 WHERE FALSE)"
    assert_sql_error 90016, "SELECT x>ANY(SELECT x) FROM SYSTEM_RANGE(1,3) GROUP BY MOD(x,2)"
  end

  def test_not_and_constant_labels_follow_reference_normalization
    result = execute("SELECT NOT(1=ANY(ARRAY[1,2])),1=ANY(ARRAY[2,NULL])")
    assert_equal [[false, nil]], result.rows
    assert_equal ["FALSE", "UNKNOWN"], result.columns
    assert_equal ["BOOLEAN", "BOOLEAN"], result.types.map(&:name)
    result = execute("SELECT NOT(v=ANY(a)),v>SOME(a) FROM (VALUES (1,ARRAY[1,2])) t(v,a)")
    assert_equal ["V <> ALL(A)", "V > ANY(A)"], result.columns
  end

  def test_query_comparisons_preserve_runtime_values_under_null_metadata_and_char_keys
    assert_equal [[false, nil]], rows("SELECT 1=ALL(SELECT * FROM UNNEST(COALESCE(ARRAY[1,2],NULL))),1=ANY(SELECT * FROM UNNEST(COALESCE(ARRAY[1,2],NULL)))")
    assert_equal [[true]], rows("SELECT CAST('a' AS CHAR(3))=ANY(SELECT * FROM UNNEST(ARRAY['a','b',NULL]))")
    assert_equal [[1], [2]], rows("SELECT DISTINCT * FROM UNNEST(COALESCE(ARRAY[1,2],NULL))")
    assert_equal [[true]], rows("SELECT 1>ANY(ARRAY[ARRAY[NULL,1]])")
  end

  def test_case_when_quantifiers_compare_the_operand_directly
    assert_equal [[1], [2], [3]], rows("SELECT CASE v WHEN =ANY(ARRAY[1]) THEN 1 WHEN >ALL(ARRAY[1]) THEN 2 ELSE 3 END FROM (VALUES 1,2,NULL) t(v)")
    assert_equal [["yes"]], rows("SELECT CASE NULL WHEN IS NOT DISTINCT FROM ANY(ARRAY[NULL]) THEN 'yes' ELSE 'no' END")
    assert_equal [[1]], rows("SELECT CASE 1 WHEN =ANY(VALUES 1,2) THEN 1 ELSE 2 END")
  end

  def test_reused_parameters_keep_typed_arrays_and_query_values_dynamic
    statement = @connection.prepare("SELECT ?=ANY(?),? IS NOT DISTINCT FROM ALL(?),?>ALL(VALUES (?),(?))")
    assert_equal [[true, false, true]], statement.execute(2, [1, 2], nil, [1, nil], 3, 1, 2).rows
    assert_equal [[false, true, nil]], statement.execute(nil, [], nil, [nil], 3, 1, nil).rows
  end

  def test_quantified_defaults_keep_captured_parameters_and_current_query_rows_after_reopen
    Dir.mktmpdir("h2-quantifiers") do |directory|
      path = File.join(directory, "db")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES(1),(2)")
        connection.execute("CREATE TABLE saved(a BOOLEAN DEFAULT ?=ANY(?),q BOOLEAN DEFAULT ?>ALL(SELECT v FROM source),c INT DEFAULT CASE ? WHEN =ANY(?) THEN 1 ELSE 2 END)", 2, [1, 2], 3, 1, [1, 2])
        connection.execute("INSERT INTO saved DEFAULT VALUES")
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO source VALUES(4)")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
        assert_equal [[true, true, 1], [true, false, 1]], connection.execute("TABLE saved").rows
        error = assert_raises(H2::Error) { connection.execute("DROP TABLE source") }
        assert_equal 90107, error.code
      end
    end
  end
end

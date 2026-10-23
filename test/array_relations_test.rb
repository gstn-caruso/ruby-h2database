# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ArrayRelationsTest < DatabaseTest
  def test_array_aggregation_retains_nulls_and_returns_null_for_empty_groups
    result = execute("SELECT ARRAY_AGG(v) AS a FROM (VALUES 3,NULL,1,3) t(v)")
    assert_equal [3, nil, 1, 3], result.rows.first.first.values
    assert_equal "INTEGER ARRAY", result.types.first.name
    assert_equal 65_536, result.types.first.precision
    assert_equal [[nil]], rows("SELECT ARRAY_AGG(v) FROM (VALUES 1) t(v) WHERE FALSE")
    assert_equal [nil], rows("SELECT ARRAY_AGG(v) FROM (VALUES CAST(NULL AS INT)) t(v)").first.first.values
  end

  def test_array_aggregate_ordering_and_distinct_retain_the_first_duplicate_sort_key
    assert_equal [nil, 1, 3], rows("SELECT ARRAY_AGG(DISTINCT v) FROM (VALUES 3,NULL,1,3) t(v)").first.first.values
    assert_equal [1, 3, 3, nil], rows("SELECT ARRAY_AGG(v ORDER BY v NULLS LAST) FROM (VALUES 3,NULL,1,3) t(v)").first.first.values
    assert_equal [5, 4], rows("SELECT ARRAY_AGG(DISTINCT a ORDER BY b) FROM (VALUES (4,3),(5,1),(5,2)) t(a,b)").first.first.values
    assert_equal [1, 2, 3], rows("SELECT ARRAY_AGG(DISTINCT a ORDER BY b) FROM (VALUES (3,1),(1,1),(2,1)) t(a,b)").first.first.values
    assert_equal [1, 2], rows("SELECT ARRAY_AGG(v ORDER BY 1 DESC) FROM (VALUES 1,2) t(v)").first.first.values
  end

  def test_filters_apply_before_arguments_for_array_and_existing_aggregates
    assert_equal [2, 1], rows("SELECT ARRAY_AGG(4/v ORDER BY v) FILTER(WHERE v<>0) FROM (VALUES 0,2,4) t(v)").first.first.values
    assert_equal [[2, 3, 1.5, 1, 2]], rows("SELECT COUNT(*) FILTER(WHERE v>0),SUM(v) FILTER(WHERE v>0),AVG(v) FILTER(WHERE v>0),MIN(v) FILTER(WHERE v>0),MAX(v) FILTER(WHERE v>0) FROM (VALUES NULL,0,1,2) t(v)")
    assert_equal [[0, nil]], rows("SELECT COUNT(*) FILTER(WHERE FALSE),ARRAY_AGG(v) FILTER(WHERE FALSE) FROM (VALUES 1,2) t(v)")
    assert_sql_error 90054, "SELECT ARRAY_AGG(SUM(v)) FROM (VALUES 1,2) t(v)"
    assert_sql_error 90054, "SELECT ARRAY_AGG(v) FILTER(WHERE COUNT(*)>0) FROM (VALUES 1,2) t(v)"
  end

  def test_array_aggregates_work_in_groups_having_and_nested_query_scopes
    result = rows("SELECT g,ARRAY_AGG(v ORDER BY v DESC) AS a FROM (VALUES ('a',1),('a',2),('b',3)) t(g,v) GROUP BY g HAVING CARDINALITY(ARRAY_AGG(v))>1 ORDER BY g")
    assert_equal [["a", [2, 1]]], result.map { |group, value| [group, value.values] }
    assert_equal [2, 3], rows("SELECT ARRAY_AGG((SELECT MAX(x) FROM SYSTEM_RANGE(1,3) WHERE x<=v) ORDER BY v) FROM (VALUES 2,3) t(v)").first.first.values
    assert_sql_error 90016, "SELECT ARRAY_AGG(v),g FROM (VALUES ('a',1),('b',2)) t(g,v)"
    assert_sql_error 42122, "SELECT ARRAY_AGG(v ORDER BY missing) FROM (VALUES 1) t(v) WHERE FALSE"
  end

  def test_unnest_pads_short_arrays_and_adds_one_based_ordinality
    assert_equal [[1, 2, 5, 1], [nil, 3, 6, 2], [nil, 4, nil, 3]], rows("SELECT * FROM UNNEST(ARRAY[1],ARRAY[2,3,4],ARRAY[5,6]) WITH ORDINALITY")
    assert_equal [[1, 1], [2, 2]], rows("SELECT v,n FROM (UNNEST(ARRAY[1,2]) WITH ORDINALITY) t(v,n) ORDER BY n")
    assert_equal [[1], [2]], rows("CALL UNNEST(ARRAY[1,2])")
    assert_sql_error 7001, "SELECT * FROM UNNEST()"
  end

  def test_unnest_preserves_template_types_for_empty_null_scalar_and_nested_inputs
    assert_equal [], rows("SELECT * FROM UNNEST(ARRAY[])")
    assert_equal [], rows("SELECT * FROM UNNEST(NULL)")
    result = execute("SELECT * FROM UNNEST(1)")
    assert_equal [[1]], result.rows
    assert_equal ["NULL"], result.types.map(&:name)
    result = execute("SELECT * FROM UNNEST(ARRAY[ARRAY[1,2],ARRAY[3]])")
    assert_equal [[1, 2], [3]], result.rows.map { it.first.values }
    assert_equal ["INTEGER ARRAY"], result.types.map(&:name)
    assert_equal [[1], [2]], rows("SELECT * FROM UNNEST(ROW(1,2))")
  end

  def test_unnest_parameters_use_parse_time_types_and_reusable_values
    statement = @connection.prepare("SELECT * FROM UNNEST(?,CAST(? AS INT ARRAY[2])) WITH ORDINALITY")
    result = statement.execute([1, 2], [3])
    assert_equal [[1, 3, 1], [2, nil, 2]], result.rows
    assert_equal ["NULL", "INTEGER", "INTEGER"], result.types.map(&:name)
    assert_equal [], statement.execute(nil, []).rows
    assert_equal [[3, 1]], rows("SELECT * FROM UNNEST(CAST(? AS INT ARRAY)) WITH ORDINALITY", [3])
  end

  def test_unnest_supports_joins_membership_and_array_aggregate_round_trips
    assert_equal [[2], [4]], rows("SELECT x FROM SYSTEM_RANGE(1,5) WHERE x IN(SELECT * FROM UNNEST(ARRAY[2,4])) ORDER BY x")
    assert_equal [[1, 3], [2, 3]], rows("SELECT a.c1,b.c1 FROM UNNEST(ARRAY[1,2]) a CROSS JOIN UNNEST(ARRAY[3]) b ORDER BY a.c1")
    assert_equal [[1], [2], [3]], rows("SELECT * FROM UNNEST((SELECT ARRAY_AGG(x ORDER BY x) FROM SYSTEM_RANGE(1,3)))")
    assert_sql_error 42122, "SELECT * FROM (VALUES ARRAY[1]) t(a),UNNEST(t.a)"
  end

  def test_numeric_common_and_operator_precision_reaches_array_components
    result = execute("SELECT ARRAY_AGG(v+1.5),ARRAY_AGG(v*1.5),ARRAY_AGG(v/1.5) FROM (VALUES 1,2) t(v)")
    assert_equal ["NUMERIC(12, 1) ARRAY", "NUMERIC(12, 1) ARRAY", "NUMERIC(14, 3) ARRAY"], result.types.map(&:name)
    assert_equal ["[2.5, 3.5]", "[1.5, 3.0]", "[0.667, 1.333]"], result.rows.first.map(&:to_s)
    result = execute("SELECT ARRAY_AGG(v/CAST(8 AS NUMERIC(1,0))) FROM (VALUES CAST(1 AS NUMERIC(1,0))) t(v)")
    assert_equal "NUMERIC(3, 2) ARRAY", result.types.first.name
    assert_equal "[0.12]", result.rows.first.first.to_s
  end

  def test_case_reachability_keeps_the_query_aggregate_flag
    assert_equal [[1]], rows("SELECT CASE WHEN FALSE THEN ARRAY_AGG(v) ELSE 1 END FROM (VALUES 1,2) t(v)")
    assert_equal [[1]], rows("SELECT CASE WHEN TRUE THEN 1 ELSE ARRAY_AGG(v) END FROM (VALUES 1,2) t(v) WHERE FALSE")
    assert_sql_error 90016, "SELECT CASE WHEN TRUE THEN v ELSE ARRAY_AGG(v) END FROM (VALUES 1,2) t(v)"
    assert_equal [[1], [2]], rows("SELECT CASE WHEN TRUE THEN v ELSE 1/0 END FROM (VALUES 1,2) t(v)")
    assert_sql_error 22012, "SELECT CASE WHEN FALSE THEN 1/0 ELSE 1 END"
  end

  def test_persisted_aggregate_defaults_keep_filters_parameters_and_unnest_templates
    Dir.mktmpdir("h2-array-relations") do |directory|
      path = File.join(directory, "relations")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES(1),(2)")
        connection.execute("CREATE TABLE saved(a INT ARRAY DEFAULT (SELECT ARRAY_AGG(v ORDER BY v DESC) FILTER(WHERE v>?) FROM source),u INT ARRAY DEFAULT (SELECT ARRAY_AGG(c1) FILTER(WHERE c1>0) FROM UNNEST(?)),c INT DEFAULT (SELECT CASE WHEN TRUE THEN 1 ELSE ARRAY_AGG(v) END FROM source))", 1, [1, 2])
        connection.execute("INSERT INTO saved DEFAULT VALUES")
        assert_equal ["[2]", "[null, null]", "1"], connection.execute("TABLE saved").rows.first.map(&:to_s)
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO source VALUES(3)")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
        assert_equal [["[2]", "[null, null]", "1"], ["[3, 2]", "[null, null]", "1"]], connection.execute("TABLE saved").rows.map { it.map(&:to_s) }
        error = assert_raises(H2::Error) { connection.execute("DROP TABLE source") }
        assert_equal 90107, error.code
      end
    end
  end
end

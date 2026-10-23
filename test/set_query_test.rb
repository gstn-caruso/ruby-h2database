# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SetQueryTest < DatabaseTest
  def test_union_distinct_and_all_retain_the_left_column_names
    result = execute("SELECT 2 AS n UNION ALL SELECT 1 AS other UNION ALL SELECT 2 ORDER BY n")
    assert_equal ["N"], result.columns
    assert_equal [[1], [2], [2]], result.rows
    assert_equal [[1], [2]], rows("VALUES 2,1,2 UNION DISTINCT VALUES 1,2 ORDER BY 1")
  end

  def test_nulls_and_duplicate_rows_use_set_equality
    assert_equal [[nil, 1], [1, nil]], rows("VALUES(NULL,1),(NULL,1),(1,NULL) UNION VALUES(1,NULL) ORDER BY 1,2")
    assert_equal [[nil], [2]], rows("VALUES NULL,1,2,2 INTERSECT VALUES NULL,2,2 ORDER BY 1")
    assert_equal [[1]], rows("VALUES NULL,1,1,2 EXCEPT VALUES NULL,2 ORDER BY 1")
    assert_empty rows("VALUES 1 INTERSECT VALUES 2")
    assert_empty rows("VALUES 1 EXCEPT VALUES 1")
  end

  def test_intersect_preserves_paginated_right_duplicates_and_conversion_collisions
    assert_equal [[1], [1]], rows("VALUES 1 INTERSECT (VALUES 1,1 LIMIT 2)")
    assert_equal [[1], [1]], rows("SELECT 1 AS n INTERSECT VALUES '1','01'")
    assert_equal [[1]], rows("VALUES 1 INTERSECT VALUES 1,1")
  end

  def test_intersection_precedence_left_association_and_parentheses
    assert_equal [[1], [2]], rows("VALUES 1 UNION VALUES 2 INTERSECT VALUES 2 ORDER BY 1")
    assert_equal [[2]], rows("(VALUES 1 UNION VALUES 2) INTERSECT VALUES 2")
    assert_equal [[2]], rows("VALUES 1 EXCEPT VALUES 1 UNION VALUES 2")
    assert_equal [[1]], rows("VALUES 1 MINUS VALUES 2")
  end

  def test_common_types_coerce_values_without_assignment_padding_or_rounding
    result = execute("SELECT 1 AS n UNION ALL SELECT 2.25 ORDER BY n")
    assert_equal ["NUMERIC"], result.types.map(&:name)
    assert_equal [[BigDecimal("1")], [BigDecimal("2.25")]], result.rows
    assert_equal [["a"]], rows("SELECT CAST('a' AS CHAR(3)) AS c UNION SELECT CAST('a' AS CHAR(1))")
    assert_equal [["a\x00\x00".b], ["b".b]], rows("SELECT CAST('a' AS BINARY(3)) AS b UNION ALL SELECT CAST('b' AS BINARY(1))")
    assert_sql_error 22018, "SELECT 1 UNION SELECT 'invalid'"
  end

  def test_binary_uuid_and_nested_row_sets
    uuid = H2::UUIDValue.parse("0" * 32)
    assert_equal [[uuid]], rows("SELECT UUID '00000000-0000-0000-0000-000000000000' AS u UNION SELECT '00000000000000000000000000000000'")
    assert_equal [["\x00".b], ["\xff".b]], rows("VALUES X'ff',X'00' UNION VALUES X'00' ORDER BY 1")
    pair = H2::RowValue.new([1, nil])
    assert_equal [[pair]], rows("SELECT ROW(1,NULL) AS r UNION SELECT ROW(1,NULL)")
    assert_equal [[H2::RowValue.new([2, nil])]], rows("SELECT ROW(1,NULL) AS r UNION SELECT ROW(2,NULL) EXCEPT SELECT ROW(1,NULL)")
  end

  def test_character_set_order_and_equality_follow_utf16_units
    assert_equal [["😀"], ["\uE000"]], rows("VALUES '😀','\uE000' UNION VALUES '😀' ORDER BY 1")
    assert_equal [["😀"]], rows("VALUES '😀' UNION VALUES U&'\\d83d\\de00'")
  end

  def test_query_lookahead_distinguishes_parentheses_from_quoted_tokens
    assert_equal [["("]], rows("SELECT ((SELECT '(') UNION SELECT '(') AS v")
    Dir.mktmpdir do |directory|
      path = File.join(directory, "quoted-sets")
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE "("(v VARCHAR)')
        connection.execute('INSERT INTO "(" VALUES(\'a\')')
        connection.execute('CREATE TABLE target(v VARCHAR DEFAULT (SELECT v FROM "(" UNION SELECT \'(\' ORDER BY 1 LIMIT 1))')
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [["("]], connection.execute("TABLE target").rows
      end
    end
  end

  def test_set_ordering_only_accepts_output_names_positions_and_constants
    assert_equal [[2], [1]], rows("SELECT 1 AS n UNION ALL SELECT 2 AS other ORDER BY n DESC")
    assert_equal [[1], [2]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY ?", 1)
    assert_equal [[2], [1]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY ?", -1)
    assert_equal [[1], [2]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY (?)", nil)
    assert_equal [[1], [2]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY +?", 1)
    assert_sql_error 90068, "SELECT 2 AS n UNION ALL SELECT 1 ORDER BY -?", 1
    assert_equal [[2], [1]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY (1)")
    assert_equal [[2], [1]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY -1")
    assert_equal [[2], [1]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY CAST(1 AS INT)")
    assert_sql_error 90068, "SELECT 1 AS n UNION SELECT 2 AS other ORDER BY other"
    assert_sql_error 90068, "SELECT 1 AS n UNION SELECT 2 ORDER BY n+1"
    assert_sql_error 90068, "VALUES 1 UNION VALUES 2 ORDER BY 2"
    assert_equal [[1, 2], [2, 1]], rows("SELECT 2 AS a,1 AS a UNION ALL SELECT 1,2 ORDER BY a")
  end

  def test_outer_pagination_and_parenthesized_branch_pagination
    assert_equal [[3], [2]], rows("VALUES 1,2 UNION ALL VALUES 3,4 ORDER BY 1 DESC OFFSET 1 ROW FETCH NEXT 2 ROWS ONLY")
    assert_equal [[3], [1]], rows("(VALUES 1,2 LIMIT 1) UNION ALL (VALUES 3,4 LIMIT 1) ORDER BY 1 DESC")
    assert_equal [[2]], rows("(VALUES 1,2 LIMIT 1) ORDER BY 1 DESC")
    assert_sql_error 42000, "(VALUES 1 LIMIT 1) LIMIT 0"
    assert_sql_error 42000, "(VALUES 1 LIMIT 1) OFFSET 0 ROWS"
  end

  def test_union_subqueries_support_correlation_membership_and_cardinality
    execute("CREATE TABLE t(v INT)")
    execute("INSERT INTO t VALUES 1,2")
    assert_equal [[1], [2]], rows("SELECT (SELECT t.v UNION ALL SELECT 0 WHERE FALSE) AS n FROM t ORDER BY v")
    assert_equal [[1], [2]], rows("SELECT v FROM t WHERE v IN(VALUES 1 UNION VALUES 2) ORDER BY v")
    assert_equal [[true]], rows("SELECT EXISTS(VALUES 1 EXCEPT VALUES 2)")
    assert_sql_error 90053, "SELECT (VALUES 1 UNION ALL VALUES 2)"
    assert_equal [[nil]], rows("SELECT (VALUES 1 INTERSECT VALUES 2) AS n")
    assert_equal ["NULL"], execute("SELECT (VALUES 1 INTERSECT VALUES 2) AS n").types.map(&:name)
    assert_equal ["1"], execute("SELECT (VALUES 1 UNION VALUES 1)").columns
    assert_equal ["1"], execute("SELECT (VALUES 1 UNION VALUES 1 ORDER BY NULL)").columns
    assert_equal ["1"], execute("SELECT (SELECT (VALUES 1 UNION VALUES 1))").columns
    assert_sql_error 42122, "SELECT * FROM t WHERE EXISTS(SELECT * FROM (SELECT t.v UNION VALUES 1) d)"
  end

  def test_binding_width_and_conversion_errors_are_not_hidden_by_empty_input
    execute("CREATE TABLE empty_values(v INT)")
    assert_sql_error 21002, "TABLE empty_values UNION SELECT 1,2"
    assert_sql_error 42122, "TABLE empty_values UNION SELECT missing FROM empty_values"
    assert_sql_error 22018, "SELECT CAST(NULL AS VARBINARY) FROM empty_values UNION SELECT 1 FROM empty_values"
    assert_sql_error 22018, "SELECT 1 UNION ALL SELECT CAST('bad' AS INT) LIMIT 1"
    assert_sql_error 22018, "SELECT 1 UNION SELECT 'bad' LIMIT 0"
    assert_sql_error 42001, "VALUES 1 INTERSECT ALL VALUES 1"
    assert_sql_error 42001, "VALUES 1 EXCEPT DISTINCT VALUES 1"
  end

  def test_insert_accepts_parenthesized_set_sources_and_preserves_statement_atomicity
    execute("CREATE TABLE t(v INT PRIMARY KEY)")
    assert_equal 2, execute("INSERT INTO t (VALUES 1 UNION ALL VALUES 2)").update_count
    assert_sql_error 23505, "INSERT INTO t SELECT 3 UNION ALL SELECT 2"
    assert_equal [[1], [2]], rows("TABLE t ORDER BY v")
  end

  def test_set_queries_work_as_sources_for_create_insert_and_update
    execute("CREATE TABLE t AS VALUES 1 UNION VALUES 2")
    assert_equal 2, execute("INSERT INTO t SELECT 2 UNION ALL SELECT 3").update_count
    assert_sql_error 42000, "INSERT INTO t VALUES 2 UNION ALL VALUES 3"
    execute("UPDATE t SET c1=(SELECT MAX(c1) FROM t UNION SELECT 0 WHERE FALSE) WHERE c1=1")
    assert_equal [[2], [2], [3], [3]], rows("TABLE t ORDER BY c1")
    assert_equal [[2], [3]], rows("SELECT DISTINCT x FROM (TABLE t UNION ALL VALUES 2) d(x) ORDER BY x")
  end

  def test_saved_defaults_keep_union_structure_captured_parameters_and_order_constants
    Dir.mktmpdir do |directory|
      path = File.join(directory, "sets")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES 2")
        connection.execute("CREATE TABLE target(v INT DEFAULT (SELECT v FROM source UNION ALL SELECT ? ORDER BY (1) LIMIT 1), p INT DEFAULT (SELECT v FROM source UNION ALL SELECT 1 ORDER BY (?) LIMIT 1))", 1, 1)
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [[2, 1]], connection.execute("TABLE target").rows
        connection.execute("UPDATE source SET v=3")
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [[2, 1], [3, 1]], connection.execute("TABLE target ORDER BY v").rows
        error = assert_raises(H2::Error) { connection.execute("DROP TABLE source") }
        assert_equal 90107, error.code
      end
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"

class SQLTest < DatabaseTest
  def test_select_literals_and_operator_precedence
    assert_equal [[7, 9, -2, 2, "it's Ruby", true, nil]],
      rows("SELECT 1 + 2 * 3, (1 + 2) * 3, -5 + 3, 5 / 2, 'it''s Ruby', TRUE, NULL;")
  end

  def test_decimal_arithmetic_is_exact
    assert_equal [[BigDecimal("0.3"), BigDecimal("2.5")]], rows("SELECT 0.1 + 0.2, 5.0 / 2")
  end

  def test_sql_null_and_three_valued_logic
    assert_equal [[nil, nil, nil, false, true, true, false, true]],
      rows("SELECT NULL = NULL, NOT NULL, TRUE AND NULL, FALSE AND NULL, TRUE OR NULL, NULL IS NULL, 1 IS NULL, NULL IS NOT DISTINCT FROM NULL")
  end

  def test_predicates
    assert_equal [[true, nil, false, true, true, false]],
      rows("SELECT 2 BETWEEN 1 AND 3, 4 IN (1, NULL), 2 NOT IN (1, 2), 'hello' LIKE 'h%o', 'a_b' LIKE 'a!_b' ESCAPE '!', 3 <> 3")
  end

  def test_values_accepts_h2_row_and_scalar_syntax
    assert_equal [[1, 2], [3, 4], [5, 6]], rows("VALUES ROW (1, 2), (3, 4), ROW (5, 6)")
    assert_equal [[1], [2]], rows("VALUES 1, 2")
    assert_sql_error 21002, "VALUES (1), (1, 2)"
  end

  def test_comments_and_quoted_identifiers
    execute('CREATE /* outer /* nested */ comment */ TABLE "Mixed Case" ("a" INT, A INT)')
    execute('INSERT INTO "Mixed Case" VALUES (1, 2) -- done')
    result = execute('SELECT "a", a AS "label" FROM "Mixed Case"')
    assert_equal ["a", "label"], result.columns
    assert_equal [[1, 2]], result.rows
  end

  def test_unterminated_tokens_are_errors
    assert_sql_error 42000, "SELECT 'abc"
    assert_sql_error 42000, 'SELECT "abc'
    assert_sql_error 42000, "SELECT 1 /* unfinished"
  end

  def test_script_executes_multiple_statements_without_splitting_strings
    result = @connection.execute_script("CREATE TABLE t(v VARCHAR); INSERT INTO t VALUES ('a;b'); SELECT * FROM t;")
    assert_equal 3, result.length
    assert_equal [["a;b"]], result.last.rows
  end

  def test_single_statement_api_rejects_trailing_statements_before_mutation
    assert_sql_error 42000, "CREATE TABLE t(a INT); DROP TABLE t"
    assert_sql_error 42102, "TABLE t"
  end

  def test_create_insert_project_filter_and_order
    execute("CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, age INT)")
    assert_equal 3, execute("INSERT INTO people VALUES (1, 'Ada', 36), (2, 'Grace', 85), (3, 'Linus', NULL)").update_count
    result = execute("SELECT name AS person, age + 1 AS age_next FROM people WHERE age >= 30 ORDER BY age DESC")
    assert_equal ["PERSON", "AGE_NEXT"], result.columns
    assert_equal [["Grace", 86], ["Ada", 37]], result.rows
    assert_equal [{"PERSON" => "Grace", "AGE_NEXT" => 86}, {"PERSON" => "Ada", "AGE_NEXT" => 37}], result.to_a
  end

  def test_prepared_parameters_are_values
    execute("CREATE TABLE t(id INT, v VARCHAR)")
    statement = @connection.prepare("INSERT INTO t VALUES (?, ?)")
    statement.execute(1, "x'); DROP TABLE t; --")
    statement.execute(2, "safe")
    assert_equal [["x'); DROP TABLE t; --"]], rows("SELECT v FROM t WHERE id = ?", 1)
    assert_sql_error 7001, "SELECT ?"
    assert_sql_error 7001, "SELECT 1", 2
    assert_equal [["?", 3]], rows("SELECT '?', ? -- ?", 3)
  end

  def test_nil_and_mutable_parameter_values
    execute("CREATE TABLE t(v VARCHAR)")
    value = +"original"
    execute("INSERT INTO t VALUES (?)", value)
    value.replace("changed")
    assert_equal [["original"]], rows("TABLE t")
    assert_equal [[nil]], rows("SELECT ?", nil)
  end

  def test_column_binding_validates_empty_tables
    execute("CREATE TABLE t(a INT)")
    assert_sql_error 42122, "SELECT missing FROM t"
    assert_sql_error 42122, "SELECT a FROM t WHERE missing = 1"
    assert_sql_error 42122, "SELECT a FROM t ORDER BY missing"
  end

  def test_table_alias_and_schema_qualification
    execute("CREATE TABLE PUBLIC.t(a INT)")
    execute("INSERT INTO t VALUES 3")
    assert_equal [[3]], rows("SELECT x.a FROM PUBLIC.t AS x WHERE x.a = 3")
    assert_equal [[3]], rows("SELECT x.* FROM t x")
    assert_sql_error 42122, "SELECT wrong.a FROM t"
    assert_sql_error 90079, "SELECT * FROM missing.t"
  end

  def test_defaults_and_column_lists
    execute("CREATE TABLE t(a INT, b INT DEFAULT 5)")
    execute("INSERT INTO t(a) VALUES 1, 2")
    execute("INSERT INTO t VALUES (3, DEFAULT)")
    execute("INSERT INTO t DEFAULT VALUES")
    assert_equal [[1, 5], [2, 5], [3, 5], [nil, 5]], rows("TABLE t")
    assert_sql_error 21002, "INSERT INTO t VALUES (1)"
    assert_sql_error 42121, "INSERT INTO t(a, a) VALUES (1, 2)"
  end

  def test_constraints_and_atomic_multi_row_insert
    execute("CREATE TABLE t(id INT PRIMARY KEY, v VARCHAR(3) NOT NULL, u INT UNIQUE)")
    execute("INSERT INTO t VALUES (1, 'one', NULL), (2, 'two', NULL)")
    assert_sql_error 23505, "INSERT INTO t VALUES (3, 'tri', 1), (1, 'bad', 2)"
    assert_equal [[1], [2]], rows("SELECT id FROM t ORDER BY id")
    assert_sql_error 23502, "INSERT INTO t VALUES (NULL, 'nil', 3)"
    assert_sql_error 23502, "INSERT INTO t VALUES (4, NULL, 3)"
    assert_sql_error 22001, "INSERT INTO t VALUES (4, 'long', 3)"
  end

  def test_composite_unique_and_primary_constraints
    execute("CREATE TABLE t(a INT, b INT, PRIMARY KEY(a, b), UNIQUE(b))")
    execute("INSERT INTO t VALUES (1, 2)")
    assert_sql_error 23505, "INSERT INTO t VALUES (2, 2)"
    assert_sql_error 23502, "INSERT INTO t VALUES (NULL, 3)"
    assert_sql_error 42122, "CREATE TABLE invalid(a INT, PRIMARY KEY(missing))"
  end

  def test_update_expressions_use_original_row_and_statement_is_atomic
    execute("CREATE TABLE t(id INT PRIMARY KEY, a INT, b INT)")
    execute("INSERT INTO t VALUES (1, 10, 20), (2, 30, 40)")
    assert_equal 1, execute("UPDATE t SET a = b, b = a WHERE id = 1").update_count
    assert_equal [[20, 10]], rows("SELECT a, b FROM t WHERE id = 1")
    assert_sql_error 23505, "UPDATE t SET id = 3"
    assert_equal [[1], [2]], rows("SELECT id FROM t ORDER BY id")
    assert_sql_error 42122, "UPDATE t SET missing = 1 WHERE FALSE"
  end

  def test_delete_truncate_and_drop
    execute("CREATE TABLE t(a INT)")
    execute("INSERT INTO t VALUES 1, 2, 3")
    assert_equal 2, execute("DELETE FROM t WHERE a > 1").update_count
    assert_equal [[1]], rows("TABLE t")
    execute("TRUNCATE TABLE t")
    assert_empty rows("TABLE t")
    execute("DROP TABLE t")
    execute("DROP TABLE IF EXISTS t")
    assert_sql_error 42102, "TABLE t"
  end

  def test_create_if_not_exists_and_duplicate_names
    execute("CREATE TABLE t(a INT)")
    execute("CREATE TABLE IF NOT EXISTS t(b INT)")
    assert_equal ["A"], execute("TABLE t").columns
    assert_sql_error 42101, "CREATE TABLE t(b INT)"
    assert_sql_error 42121, "CREATE TABLE t2(a INT, a INT)"
  end

  def test_distinct_limit_offset_and_null_ordering
    execute("CREATE TABLE t(a INT)")
    execute("INSERT INTO t VALUES 3, NULL, 1, 3, 2")
    assert_equal [[nil], [1], [2], [3]], rows("SELECT DISTINCT a FROM t ORDER BY a")
    assert_equal [[3], [3], [2]], rows("SELECT a FROM t ORDER BY a DESC LIMIT 3")
    assert_equal [[2]], rows("SELECT DISTINCT a FROM t ORDER BY a NULLS LAST OFFSET 1 ROW FETCH NEXT 1 ROW ONLY")
    assert_equal [[2], [3]], rows("SELECT DISTINCT a FROM t ORDER BY a LIMIT ? OFFSET ?", 2, 2)
  end

  def test_order_by_alias_and_position
    execute("CREATE TABLE t(a INT, b INT)")
    execute("INSERT INTO t VALUES (1, 20), (2, 10)")
    assert_equal [[12], [21]], rows("SELECT a + b AS total FROM t ORDER BY total")
    assert_equal [[2, 10], [1, 20]], rows("SELECT a, b FROM t ORDER BY 2")
  end

  def test_aggregate_functions_with_empty_and_null_inputs
    execute("CREATE TABLE t(a INT)")
    assert_equal [[0, 0, nil, nil, nil, nil]], rows("SELECT COUNT(*), COUNT(a), SUM(a), AVG(a), MIN(a), MAX(a) FROM t")
    execute("INSERT INTO t VALUES 2, 4, NULL, 4")
    assert_equal [[4, 3, 10, 10.0 / 3, 2, 4, 2]],
      rows("SELECT COUNT(*), COUNT(a), SUM(a), AVG(a), MIN(a), MAX(a), COUNT(DISTINCT a) FROM t")
  end

  def test_group_by_and_having
    execute("CREATE TABLE t(category VARCHAR, amount INT)")
    execute("INSERT INTO t VALUES ('a', 10), ('a', 20), ('b', 5), (NULL, 8)")
    assert_equal [["a", 30]], rows("SELECT category, SUM(amount) AS total FROM t GROUP BY category HAVING SUM(amount) > 10 ORDER BY total")
    assert_sql_error 90016, "SELECT amount, COUNT(*) FROM t"
  end

  def test_scalar_functions_and_cast
    assert_equal [["HELLO", "hello", 3, "fallback", -2, 12, BigDecimal("1.24")]],
      rows("SELECT UPPER('hello'), LOWER('HELLO'), LENGTH('hé!'), COALESCE(NULL, 'fallback'), ABS(-2) * -1, CAST('12' AS INT), CAST(1.235 AS NUMERIC(3, 2))")
    assert_sql_error 22018, "SELECT CAST('oops' AS INT)"
    assert_sql_error 22003, "SELECT CAST(2147483648 AS INT)"
    assert_sql_error 22012, "SELECT 1 / 0"
  end

  def test_unsupported_features_fail_explicitly
    assert_sql_error 50100, "CREATE VIEW v AS SELECT 1"
    assert_sql_error 42000, "SELECT 1 nonsense nonsense"
    assert_sql_error 50100, "SELECT unknown_function(1)"
  end

  def test_results_cannot_mutate_database_state
    execute("CREATE TABLE t(v VARCHAR)")
    execute("INSERT INTO t VALUES ('original')")
    result = execute("TABLE t")
    assert_raises(FrozenError) { result.rows.first[0].replace("changed") }
    assert_raises(FrozenError) { result.rows.first << "changed" }
    assert_equal [["original"]], rows("TABLE t")
  end
end

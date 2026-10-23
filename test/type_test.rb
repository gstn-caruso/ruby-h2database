# frozen_string_literal: true

require_relative "test_helper"

class TypeTest < DatabaseTest
  def test_cast_rounds_integer_values_half_away_from_zero
    assert_equal [[2, -2, 1, 0]], rows("SELECT CAST(1.5 AS INT), CAST(-1.5 AS INT), CAST(TRUE AS INT), CAST(FALSE AS INT)")
    assert_equal [[-2, -2]], rows("SELECT -5 / 2, 5 / -2")
  end

  def test_assignment_rejects_long_strings_but_explicit_cast_truncates
    execute("CREATE TABLE t(v VARCHAR(3), c CHAR(3))")
    assert_sql_error 22001, "INSERT INTO t VALUES ('long', 'ok')"
    assert_equal [["lon", "lon", "a  "]], rows("SELECT CAST('long' AS VARCHAR(3)), CAST('long' AS CHAR(3)), CAST('a' AS CHAR(3))")
    execute("INSERT INTO t VALUES ('ok', 'a   ')")
    assert_equal [["ok", "a  "]], rows("TABLE t")
  end

  def test_numeric_precision_and_scale
    execute("CREATE TABLE t(n NUMERIC(4, 2))")
    execute("INSERT INTO t VALUES (12.345)")
    assert_equal [[BigDecimal("12.35")]], rows("TABLE t")
    assert_sql_error 22001, "INSERT INTO t VALUES (100)"
    assert_equal [[BigDecimal("1"), 1.0]], rows("SELECT CAST(TRUE AS NUMERIC), CAST(TRUE AS DOUBLE)")
  end

  def test_integer_arithmetic_checks_overflow
    assert_sql_error 22003, "SELECT CAST(2147483647 AS INT) + 1"
    assert_sql_error 22003, "SELECT CAST(-2147483648 AS INT) / -1"
    assert_equal [[2_147_483_648]], rows("SELECT CAST(2147483647 AS BIGINT) + 1")
  end

  def test_aggregate_return_types_follow_h2
    execute("CREATE TABLE t(i INT, b BIGINT, n NUMERIC(5, 2))")
    execute("INSERT INTO t VALUES (1, 1, 1.01), (2, 2, 2.02)")
    assert_equal [[1.5, BigDecimal("1.5"), BigDecimal("1.515")]], rows("SELECT AVG(i), AVG(b), AVG(n) FROM t")
  end

  def test_boolean_tests_convert_their_operand
    assert_equal [[true, true, true, false]], rows("SELECT 1 IS TRUE, 0 IS FALSE, NULL IS NOT TRUE, NULL IS FALSE")
    assert_equal [[true, false, true]], rows("SELECT CAST(' yes ' AS BOOLEAN), CAST('0.0' AS BOOLEAN), CAST('-2' AS BOOLEAN)")
  end

  def test_real_conversion_rounds_to_ieee_single_precision
    assert_equal [[16_777_216.0]], rows("SELECT CAST(16777217 AS REAL)")
  end

  def test_abs_checks_the_argument_integer_range
    assert_sql_error 22003, "SELECT ABS(CAST(-2147483648 AS INT))"
    assert_sql_error 22003, "SELECT ABS(CAST(-9223372036854775808 AS BIGINT))"
  end

  def test_h2_error_states_are_exposed
    error = assert_sql_error(42102, "TABLE missing")
    assert_equal "42S02", error.sql_state
    error = assert_sql_error(7001, "SELECT ?")
    assert_equal "07001", error.sql_state
  end

  def test_qualified_group_columns_bind_to_the_same_column
    execute("CREATE TABLE t(a INT)")
    execute("INSERT INTO t VALUES 1, 1, 2")
    assert_equal [[1, 2], [2, 1]], rows("SELECT t.a, COUNT(*) FROM t GROUP BY a ORDER BY a")
  end

  def test_defaults_capture_parameters_and_reject_column_references
    execute("CREATE TABLE t(a INT DEFAULT ?)", 1)
    execute("INSERT INTO t DEFAULT VALUES")
    assert_equal [[1]], rows("TABLE t")
    assert_sql_error 42122, "CREATE TABLE invalid(a INT DEFAULT missing)"
  end
end

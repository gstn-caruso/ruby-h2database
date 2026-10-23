# frozen_string_literal: true

require_relative "test_helper"

class SubqueryTest < DatabaseTest
  def setup
    super
    execute("CREATE TABLE parents(id INT PRIMARY KEY, name VARCHAR)")
    execute("CREATE TABLE children(id INT PRIMARY KEY, parent_id INT, amount INT)")
    execute("INSERT INTO parents VALUES (1, 'Ada'), (2, 'Grace'), (3, 'Linus')")
    execute("INSERT INTO children VALUES (10, 1, 5), (11, 1, 8), (12, 2, NULL)")
  end

  def test_scalar_subquery_returns_value_null_or_cardinality_error
    assert_equal [[42]], rows("SELECT (SELECT 42) AS answer")
    assert_equal [[nil]], rows("SELECT (SELECT amount FROM children WHERE id = 999) AS missing")
    assert_sql_error 90053, "SELECT (TABLE parents) AS too_many"
    assert_equal [[1]], rows("SELECT (SELECT id FROM parents ORDER BY id FETCH FIRST ROW ONLY) AS first_id")
    assert_sql_error 90053, "SELECT (SELECT x FROM SYSTEM_RANGE(1, 9223372036854775807))"
  end

  def test_multi_column_scalar_subquery_returns_an_immutable_row
    result = execute("SELECT (SELECT id, name FROM parents WHERE id = 1) AS parent")
    value = result.rows.first.first
    assert_instance_of H2::RowValue, value
    assert_equal [1, "Ada"], value.values
    assert_equal "ROW", result.types.first.name
    assert_raises(FrozenError) { value.values << 3 }
    assert_raises(FrozenError) { value.values[1].replace("changed") }
    assert_equal [nil, nil], rows("SELECT (SELECT id, name FROM parents WHERE FALSE)").first.first.values
  end

  def test_correlated_subqueries_keep_each_outer_row_separate
    assert_equal [[1, 13], [2, nil], [3, nil]], rows("SELECT p.id, (SELECT SUM(c.amount) FROM children c WHERE c.parent_id = p.id) AS total FROM parents p ORDER BY p.id")
    assert_equal [[1, 2], [2, 1], [3, 0]], rows("SELECT p.id, (SELECT COUNT(*) FROM children c WHERE c.parent_id = p.id) AS total FROM parents p ORDER BY p.id")
  end

  def test_nested_correlation_and_alias_shadowing
    assert_equal [[1], [2], [3]], rows("SELECT (SELECT (SELECT p.id)) AS answer_value FROM parents p ORDER BY p.id")
    assert_equal [[99], [99], [99]], rows("SELECT (SELECT p.id FROM (VALUES 99) p(id)) AS answer_value FROM parents p ORDER BY p.id")
    assert_equal [[1], [2], [3]], rows("SELECT (SELECT p.id FROM (VALUES 99) p(other_id)) AS answer_value FROM parents p ORDER BY p.id")
  end

  def test_unqualified_local_names_take_precedence_over_outer_names
    assert_equal [[1, 10], [2, 10], [3, 10]], rows("SELECT p.id, (SELECT id FROM children ORDER BY id FETCH FIRST ROW ONLY) AS child FROM parents p ORDER BY p.id")
    assert_equal [[1], [2], [3]], rows("SELECT (SELECT id FROM (VALUES 99) t(other_id)) AS answer_value FROM parents p ORDER BY p.id")
  end

  def test_exists_and_not_exists_with_correlation
    assert_equal [[1], [2]], rows("SELECT p.id FROM parents p WHERE EXISTS (SELECT * FROM children c WHERE c.parent_id = p.id) ORDER BY p.id")
    assert_equal [[3]], rows("SELECT p.id FROM parents p WHERE NOT EXISTS (SELECT * FROM children c WHERE c.parent_id = p.id)")
    assert_equal [[true, false, true]], rows("SELECT EXISTS(SELECT * FROM SYSTEM_RANGE(1, 9223372036854775807)), EXISTS(SELECT 1 WHERE FALSE), EXISTS(SELECT COUNT(*) FROM parents WHERE FALSE)")
    assert_sql_error 22012, "SELECT EXISTS(SELECT 1/x FROM SYSTEM_RANGE(0, 0))"
    assert_equal [[false]], rows("SELECT EXISTS(SELECT * FROM parents LIMIT 1 OFFSET 10)")
  end

  def test_in_subquery_uses_sql_null_semantics_including_empty_sets
    assert_equal [[true, nil, nil, false, true]], rows("SELECT 5 IN (SELECT amount FROM children), 4 IN (SELECT amount FROM children), NULL IN (TABLE parents), NULL IN (SELECT amount FROM children WHERE FALSE), NULL NOT IN (SELECT amount FROM children WHERE FALSE)")
    assert_equal [[1], [2]], rows("SELECT p.id FROM parents p WHERE p.id IN (SELECT parent_id FROM children) ORDER BY p.id")
    assert_equal [[3]], rows("SELECT p.id FROM parents p WHERE p.id NOT IN (SELECT parent_id FROM children) ORDER BY p.id")
  end

  def test_in_subquery_can_be_correlated
    assert_equal [[1], [2]], rows("SELECT p.id FROM parents p WHERE p.id IN (SELECT c.parent_id FROM children c WHERE c.parent_id = p.id) ORDER BY p.id")
    assert_equal [[1]], rows("SELECT p.id FROM parents p WHERE 8 IN (SELECT c.amount FROM children c WHERE c.parent_id = p.id)")
  end

  def test_row_constructors_and_comparisons
    assert_equal [[true, nil, false, true, true]], rows("SELECT (1, 2) = ROW(1, 2), (1, NULL) = (1, NULL), (1, NULL) = (2, NULL), (1, NULL) IS NOT DISTINCT FROM (1, NULL), (1, NULL) < (2, NULL)")
    assert_equal [[false, false, true, true]], rows("SELECT ROW(NULL, 1) IS NULL, ROW(NULL, 1) IS NOT NULL, ROW(NULL, NULL) IS NULL, ROW(1, 2) IS NOT NULL")
    assert_equal [[true, nil, nil]], rows("SELECT (1, 2) IN (VALUES (1, 2), (3, 4)), (1, NULL) IN (VALUES (1, NULL)), (1, NULL) IN (VALUES (2, NULL))")
    assert_sql_error 90110, "SELECT (1, 2) IN (SELECT 1)"
  end

  def test_subqueries_validate_columns_on_empty_outer_inputs
    execute("CREATE TABLE empty_table(id INT)")
    assert_sql_error 42122, "SELECT (SELECT missing FROM children) FROM empty_table"
    assert_sql_error 42122, "SELECT id FROM empty_table WHERE EXISTS(SELECT missing FROM children)"
    assert_sql_error 42102, "SELECT (SELECT id FROM missing_table) FROM empty_table"
    assert_sql_error 90059, "SELECT (SELECT id FROM parents JOIN children ON FALSE) FROM empty_table"
  end

  def test_parameter_numbering_and_repeated_execution
    statement = @connection.prepare("SELECT p.id, (SELECT ? + p.id) AS answer_value FROM parents p WHERE EXISTS(SELECT 1 FROM children c WHERE c.parent_id = p.id AND c.amount > ?) ORDER BY p.id")
    assert_equal 2, statement.parameter_count
    assert_equal [[1, 11]], statement.execute(10, 6).rows
    assert_equal [[1, 21]], statement.execute(20, 4).rows
    assert_empty statement.execute(20, 10).rows
  end

  def test_correlation_inside_derived_sources_reaches_only_outer_query_levels
    assert_sql_error 42122, "SELECT (SELECT t.v FROM (SELECT p.id AS v) t) AS answer_value FROM parents p ORDER BY p.id"
    assert_sql_error 42122, "SELECT * FROM parents p JOIN (SELECT p.id AS v) t ON TRUE"
  end

  def test_correlation_in_joins_and_range_arguments
    assert_sql_error 42122, "SELECT (SELECT MAX(x) FROM SYSTEM_RANGE(1, p.id)) AS answer_value FROM parents p ORDER BY p.id"
    assert_equal [[1], [2]], rows("SELECT p.id FROM parents p WHERE EXISTS(SELECT * FROM children c JOIN (VALUES 1) t(v) ON c.parent_id = p.id) ORDER BY p.id")
  end

  def test_grouped_correlated_queries_validate_outer_columns
    assert_equal [[1, 2], [2, 1], [3, 0]], rows("SELECT p.id, (SELECT COUNT(*) FROM children c WHERE c.parent_id = p.id) AS total FROM parents p GROUP BY p.id ORDER BY p.id")
    assert_equal [["Ada", 2], ["Grace", 1], ["Linus", 0]], rows("SELECT p.name, (SELECT COUNT(*) FROM children c WHERE c.parent_id = p.id) AS total FROM parents p GROUP BY p.name ORDER BY p.name")
    execute("INSERT INTO parents VALUES (4, 'Ada')")
    assert_sql_error 90016, "SELECT p.name, (SELECT COUNT(*) FROM children c WHERE c.parent_id = p.id) AS total FROM parents p GROUP BY p.name"
    execute("DELETE FROM parents WHERE id = 4")
    assert_equal [[1, 1], [2, 2], [3, 3]], rows("SELECT p.id, (SELECT p.id + COUNT(*) FROM children c WHERE FALSE) AS total FROM parents p ORDER BY p.id")
  end

  def test_subqueries_in_update_delete_and_insert_are_atomic
    execute("UPDATE children SET amount = (SELECT p.id * 10 FROM parents p WHERE p.id = children.parent_id)")
    assert_equal [[10, 10], [11, 10], [12, 20]], rows("SELECT id, amount FROM children ORDER BY id")
    assert_sql_error 90053, "UPDATE children SET amount = (SELECT id FROM parents)"
    assert_equal [[10], [10], [20]], rows("SELECT amount FROM children ORDER BY id")
    execute("INSERT INTO children VALUES (13, (SELECT id FROM parents WHERE id = 3), (SELECT 30))")
    assert_equal 1, execute("DELETE FROM parents WHERE NOT EXISTS(SELECT 1 FROM children WHERE children.parent_id = parents.id AND children.amount < 30)").update_count
    assert_equal [[1], [2]], rows("SELECT id FROM parents ORDER BY id")
  end

  def test_correlated_pagination_is_applied_before_scalar_cardinality_check
    assert_sql_error 42122, "SELECT (SELECT x FROM SYSTEM_RANGE(1, 10) LIMIT 1 OFFSET p.id - 1) AS answer_value FROM parents p ORDER BY p.id"
    assert_equal [[3]], rows("SELECT (SELECT x FROM SYSTEM_RANGE(1, 10) LIMIT 1 OFFSET 2) AS answer_value")
  end

  def test_case_expression_evaluates_only_the_selected_result
    assert_equal [[1, 3, "fallback", nil]], rows("SELECT CASE WHEN TRUE THEN 1 ELSE 1/0 END, CASE 2 WHEN 1 THEN 1 WHEN 2 THEN 3 ELSE 1/0 END, CASE NULL WHEN NULL THEN 'equal' ELSE 'fallback' END, CASE WHEN FALSE THEN 1 END")
    result = execute("SELECT CASE WHEN TRUE THEN 1 ELSE 2.5 END")
    assert_equal [[1]], result.rows
    assert_equal "INTEGER", result.types.first.name
    assert_equal [[1]], rows("SELECT CASE WHEN TRUE THEN 1 ELSE missing END")
    assert_sql_error 42122, "SELECT CASE WHEN FALSE THEN missing ELSE 1 END"
    assert_equal [[BigDecimal("1")]], rows("SELECT CASE WHEN ? THEN 1 ELSE 2.5 END", true)
    assert_equal [[1, "has children"], [2, "has children"], [3, "empty"]], rows("SELECT p.id, CASE WHEN EXISTS(SELECT 1 FROM children c WHERE c.parent_id = p.id) THEN 'has children' ELSE 'empty' END AS description FROM parents p ORDER BY p.id")
    value = rows("SELECT CASE WHEN TRUE THEN ROW(1, NULL) ELSE ROW(2, 3) END").first.first
    assert_equal [1, nil], value.values
  end

  def test_defaults_evaluate_subqueries_against_current_data_and_keep_creation_parameters
    execute("CREATE TABLE defaults(v INT DEFAULT (SELECT MAX(id) FROM parents) + ?, other INT)", 10)
    execute("INSERT INTO defaults(other) VALUES (?)", 99)
    execute("UPDATE parents SET id = 5 WHERE id = 3")
    execute("INSERT INTO defaults(other) VALUES (?)", 100)
    assert_equal [[13, 99], [15, 100]], rows("TABLE defaults ORDER BY other")
    execute("UPDATE defaults SET v = DEFAULT WHERE other = 99")
    assert_equal [[15, 99], [15, 100]], rows("TABLE defaults ORDER BY other")
  end

  def test_single_field_rows_compare_to_scalars_and_between_propagates_null
    assert_sql_error 22018, "SELECT ROW(1) = 1"
    assert_equal [[true, nil]], rows("SELECT ROW(1) IN (SELECT 1), (1, NULL) BETWEEN (1, 0) AND (2, 0)")
    assert_sql_error 21002, "SELECT (1, 2) IN (SELECT ROW(1, 2))"
  end
end

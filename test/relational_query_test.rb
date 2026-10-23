# frozen_string_literal: true

require_relative "test_helper"

class RelationalQueryTest < DatabaseTest
  def setup
    super
    execute("CREATE TABLE departments(id INT PRIMARY KEY, label VARCHAR)")
    execute("CREATE TABLE people(id INT PRIMARY KEY, department_id INT, name VARCHAR)")
    execute("INSERT INTO departments VALUES (10, 'Engineering'), (20, 'Support'), (30, 'Empty')")
    execute("INSERT INTO people VALUES (1, 10, 'Ada'), (2, 10, 'Grace'), (3, 20, 'Linus'), (4, NULL, 'Unassigned')")
  end

  def test_inner_join_retains_column_provenance
    result = execute("SELECT p.id, d.id, p.name, d.label FROM people p JOIN departments d ON p.department_id = d.id ORDER BY p.id")
    assert_equal %w[ID ID NAME LABEL], result.columns
    assert_equal [[1, 10, "Ada", "Engineering"], [2, 10, "Grace", "Engineering"], [3, 20, "Linus", "Support"]], result.rows
  end

  def test_self_join_uses_separate_bindings
    assert_equal [[1, 2], [2, 1]], rows("SELECT a.id, b.id FROM people a INNER JOIN people b ON a.department_id = b.department_id AND a.id <> b.id ORDER BY a.id")
  end

  def test_ambiguous_names_and_duplicate_aliases_are_errors_even_on_empty_inputs
    assert_sql_error 90059, "SELECT id FROM people JOIN departments ON FALSE"
    assert_sql_error 90059, "SELECT p.id FROM people p JOIN departments d ON id = 10"
    assert_sql_error 42123, "SELECT * FROM people a JOIN departments a ON FALSE"
    assert_sql_error 42122, "SELECT p.id FROM people p JOIN departments d ON d.missing = p.id"
    assert_sql_error 42122, "SELECT people.id FROM people p JOIN departments d ON FALSE"
  end

  def test_left_join_preserves_unmatched_rows_and_null_does_not_equal_null
    assert_equal [[1, "Engineering"], [2, "Engineering"], [3, "Support"], [4, nil]],
      rows("SELECT p.id, d.label FROM people p LEFT OUTER JOIN departments d ON p.department_id = d.id ORDER BY p.id")
    assert_equal [[4]], rows("SELECT p.id FROM people p LEFT JOIN departments d ON p.department_id = d.id WHERE d.id IS NULL")
    assert_equal [[nil, nil]], rows("SELECT * FROM (VALUES NULL) a(x) JOIN (VALUES NULL) b(y) ON a.x IS NOT DISTINCT FROM b.y")
    assert_empty rows("SELECT * FROM (VALUES NULL) a(x) JOIN (VALUES NULL) b(y) ON a.x = b.y")
  end

  def test_right_join_preserves_right_rows_and_source_column_order
    result = execute("SELECT p.name, d.label FROM people p RIGHT JOIN departments d ON p.department_id = d.id ORDER BY d.id, p.id")
    assert_equal [["Ada", "Engineering"], ["Grace", "Engineering"], ["Linus", "Support"], [nil, "Empty"]], result.rows
    assert_equal %w[ID DEPARTMENT_ID NAME ID LABEL], execute("SELECT * FROM people RIGHT JOIN departments ON FALSE").columns
  end

  def test_cross_join_comma_and_parameter_binding
    assert_equal [[1, 3], [1, 4], [2, 3], [2, 4]], rows("SELECT a.x, b.x FROM (VALUES 1, 2) a(x) CROSS JOIN (VALUES 3, 4) b(x) ORDER BY a.x, b.x")
    assert_equal [[2, 3], [2, 4]], rows("SELECT a.x, b.x FROM (VALUES 1, 2) a(x), (VALUES 3, 4) b(x) WHERE a.x = ? ORDER BY b.x", 2)
    assert_equal [[12]], rows("SELECT COUNT(*) FROM people p CROSS JOIN departments d")
  end

  def test_join_parentheses_control_outer_join_association
    execute("CREATE TABLE a(a INT)")
    execute("CREATE TABLE b(b INT)")
    execute("CREATE TABLE c(c INT)")
    execute("INSERT INTO a VALUES 1")
    execute("INSERT INTO b VALUES 1")
    execute("INSERT INTO c VALUES 1, 2")
    assert_equal [[1, 1, 1], [nil, nil, 2]], rows("SELECT * FROM a INNER JOIN b ON a = b RIGHT OUTER JOIN c ON c = a ORDER BY c")
    assert_equal [[1, 1, 1], [2, nil, nil]], rows("SELECT * FROM c LEFT JOIN (a INNER JOIN b ON b = a) ON c = a ORDER BY c")
    assert_equal [[1, 1, 1]], rows("SELECT * FROM c LEFT JOIN a ON c = a INNER JOIN b ON b = a")
  end

  def test_nested_join_specifications_follow_h2_grammar
    assert_equal [[2, 2, 2]], rows("SELECT * FROM SYSTEM_RANGE(1, 3) t1 INNER JOIN SYSTEM_RANGE(2, 3) t2 INNER JOIN SYSTEM_RANGE(1, 2) t3 ON t3.x = t2.x ON t1.x = t2.x")
  end

  def test_using_merges_wildcard_columns_in_declared_key_order
    result = execute("SELECT * FROM (VALUES (1, 10, 'L'), (2, 20, 'M')) a(id, code, l) JOIN (VALUES (1, 10, 'R'), (3, 30, 'S')) b(id, code, r) USING (code, id)")
    assert_equal %w[CODE ID L R], result.columns
    assert_equal [[10, 1, "L", "R"]], result.rows
    assert_equal [[1, 1, 10, 10]], rows("SELECT a.id, b.id, a.code, b.code FROM (VALUES (1, 10)) a(id, code) JOIN (VALUES (1, 10)) b(id, code) USING (id)")
    assert_sql_error 42122, "SELECT * FROM people JOIN departments USING (missing)"
    result = execute("SELECT * FROM people JOIN departments USING (id, id)")
    assert_empty result.rows
    assert_equal %w[ID DEPARTMENT_ID NAME LABEL], result.columns
  end

  def test_using_on_outer_joins_keeps_the_preserved_key
    assert_equal [[1, "a", nil], [2, "b", "c"]], rows("SELECT * FROM (VALUES (1, 'a'), (2, 'b')) l(k, v) LEFT JOIN (VALUES (2, 'c'), (3, 'd')) r(k, w) USING (k) ORDER BY k")
    assert_equal [[2, "b", "c"], [3, nil, "d"]], rows("SELECT * FROM (VALUES (1, 'a'), (2, 'b')) l(k, v) RIGHT JOIN (VALUES (2, 'c'), (3, 'd')) r(k, w) USING (k) ORDER BY k")
    assert_sql_error 90059, "SELECT l.k, r.k, k FROM (VALUES 1) l(k) RIGHT JOIN (VALUES 3) r(k) USING(k)"
    assert_equal [[nil, 3]], rows("SELECT l.k, r.k FROM (VALUES 1) l(k) RIGHT JOIN (VALUES 3) r(k) USING(k)")
  end

  def test_qualified_stars_include_original_join_columns
    result = execute("SELECT l.*, r.* FROM (VALUES (1, 'a')) l(k, v) JOIN (VALUES (1, 'b')) r(k, w) USING (k)")
    assert_equal %w[K V K W], result.columns
    assert_equal [[1, "a", 1, "b"]], result.rows
  end

  def test_natural_join_and_natural_join_without_common_columns
    assert_equal [[1, "a", "b"]], rows("SELECT * FROM (VALUES (1, 'a'), (2, 'c')) l(k, v) NATURAL JOIN (VALUES (1, 'b')) r(k, w)")
    assert_equal [[1, 2]], rows("SELECT * FROM (VALUES 1) l(a) NATURAL JOIN (VALUES 2) r(b)")
  end

  def test_grouping_and_ordering_distinguish_qualified_columns
    assert_equal [[10, 2], [20, 1], [30, 0]], rows("SELECT d.id, COUNT(p.id) AS people_count FROM departments d LEFT JOIN people p ON d.id = p.department_id GROUP BY d.id ORDER BY d.id")
    assert_sql_error 90016, "SELECT p.id, COUNT(*) FROM people p JOIN departments d ON p.department_id = d.id GROUP BY d.id"
    assert_sql_error 90059, "SELECT d.id, COUNT(*) FROM departments d JOIN people p ON d.id = p.department_id GROUP BY id ORDER BY d.id"
  end

  def test_derived_tables_have_their_own_scope_and_column_names
    assert_equal [[2, "b"]], rows("SELECT t.a, t.b FROM (VALUES (1, 'a'), (2, 'b')) AS t(a, b) WHERE t.a > 1")
    assert_equal [[1], [2]], rows("SELECT a FROM (SELECT id AS a FROM people ORDER BY id FETCH FIRST 2 ROWS ONLY) t ORDER BY a")
    assert_equal [[1, 10, "Ada"]], rows("SELECT * FROM (TABLE people) t WHERE id = 1")
    assert_equal [[1]], rows("SELECT a.i FROM (VALUES 1) a(i) JOIN (SELECT a.i FROM (VALUES 1) a(i) JOIN (SELECT 1 AS i) b ON a.i = b.i) b ON a.i = b.i")
    assert_sql_error 42122, "SELECT p.id FROM (SELECT id FROM people p) t"
    assert_sql_error 42121, "SELECT * FROM (VALUES (1, 2)) t(a, a)"
    assert_sql_error 21002, "SELECT * FROM (VALUES (1, 2)) t(a)"
  end

  def test_alias_column_lists_rename_base_tables_and_hide_old_names
    assert_equal [[10]], rows("SELECT d.dept_key FROM departments d(dept_key, description) WHERE d.dept_key = 10")
    assert_sql_error 42122, "SELECT id FROM departments d(dept_key, description)"
  end

  def test_derived_values_preserve_types_across_query_boundaries
    assert_equal [[BigDecimal("1.5")]], rows("SELECT AVG(t.x) FROM (VALUES CAST(1 AS BIGINT), CAST(2 AS BIGINT)) t(x)")
    result = execute("SELECT t.x FROM (VALUES (1), (2.5)) t(x) ORDER BY t.x")
    assert_equal [[BigDecimal("1")], [BigDecimal("2.5")]], result.rows
    assert_equal "NUMERIC", result.types.first.name
  end

  def test_range_boundaries_steps_and_large_counts
    assert_equal [[1], [3], [5]], rows("SELECT * FROM SYSTEM_RANGE(1, 6, 2)")
    assert_equal [[6], [4], [2]], rows("SELECT * FROM GENERATE_SERIES(6, 1, -2) ORDER BY x DESC")
    assert_empty rows("SELECT * FROM SYSTEM_RANGE(2, 1)")
    assert_equal [[2_111_222_334]], rows("SELECT COUNT(*) FROM SYSTEM_RANGE(0, 2111222333)")
    assert_equal [[2_111_222_334]], rows("SELECT COUNT(*) FROM SYSTEM_RANGE(0, 2111222333) r")
    assert_sql_error 90142, "SELECT * FROM SYSTEM_RANGE(1, 2, 0)"
    assert_sql_error 90142, "SELECT COUNT(*) FROM SYSTEM_RANGE(2, 1, 0)"
    statement = @connection.prepare("SELECT * FROM SYSTEM_RANGE(?, ?, ?) ORDER BY x")
    assert_equal [[2], [4], [6]], statement.execute(2, 6, 2).rows
    assert_equal [[3]], statement.execute(3, 3, 1).rows
  end

  def test_limits_stream_large_range_scans
    assert_equal [[3], [4]], rows("SELECT x FROM SYSTEM_RANGE(1, 9223372036854775807) r WHERE x > 1 LIMIT 2 OFFSET 1")
    assert_empty rows("SELECT x FROM SYSTEM_RANGE(1, 9223372036854775807) LIMIT 0")
  end

  def test_create_table_as_query_infers_or_converts_columns
    execute("CREATE TABLE copied AS SELECT id, name FROM people WHERE department_id = 10")
    assert_equal [[1, "Ada"], [2, "Grace"]], rows("TABLE copied ORDER BY id")
    assert_sql_error 22003, "INSERT INTO copied VALUES (2147483648, 'too large')"
    execute("CREATE TABLE explicit(id INT PRIMARY KEY, name VARCHAR(2)) AS VALUES (5, 'ok')")
    assert_equal [[5, "ok"]], rows("TABLE explicit")
    assert_sql_error 21002, "CREATE TABLE invalid(a INT) AS VALUES (1, 2)"
    assert_sql_error 23505, "CREATE TABLE duplicate_ids(id INT PRIMARY KEY) AS VALUES 1, 1"
    assert_sql_error 42102, "TABLE duplicate_ids"
    execute("CREATE TABLE empty_copy AS TABLE people WITH NO DATA")
    assert_empty rows("TABLE empty_copy")
    assert_equal %w[ID DEPARTMENT_ID NAME], execute("TABLE empty_copy").columns
  end

  def test_insert_select_is_atomic_and_reads_the_original_target
    execute("CREATE TABLE target(id INT PRIMARY KEY, name VARCHAR)")
    assert_equal 2, execute("INSERT INTO target(name, id) SELECT name, id FROM people WHERE department_id = 10").update_count
    assert_equal 2, execute("INSERT INTO target SELECT id + 10, name FROM target").update_count
    assert_equal [[1], [2], [11], [12]], rows("SELECT id FROM target ORDER BY id")
    assert_sql_error 23505, "INSERT INTO target SELECT id, name FROM people"
    assert_equal [[1], [2], [11], [12]], rows("SELECT id FROM target ORDER BY id")
    assert_sql_error 21002, "INSERT INTO target SELECT id FROM people"
  end

  def test_drop_multiple_tables_validates_before_removing_any
    assert_sql_error 42102, "DROP TABLE people, absent"
    assert_equal [[4]], rows("SELECT COUNT(*) FROM people")
    execute("DROP TABLE people, departments")
    assert_sql_error 42102, "TABLE people"
    assert_sql_error 42102, "TABLE departments"
  end
end

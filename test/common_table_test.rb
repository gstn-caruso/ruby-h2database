# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CommonTableTest < DatabaseTest
  def test_ctes_resolve_sequentially_and_keep_explicit_or_inferred_columns
    result = execute("WITH a(x) AS (VALUES 1,2), b(y) AS (SELECT x+1 FROM a) SELECT x,y FROM a JOIN b ON x=y ORDER BY x")
    assert_equal %w[X Y], result.columns
    assert_equal [[2, 2]], result.rows
    assert_equal [[1, 2]], rows("WITH q AS (SELECT 1 AS a,2 AS b) TABLE q")
    assert_equal %w[X C2], execute("WITH q(x) AS (VALUES(1,2)) TABLE q").columns
    assert_equal %w[X], execute("WITH q(x,unused) AS (VALUES 1) TABLE q").columns
  end

  def test_nested_scopes_shadow_ctes_and_do_not_leak_to_other_statements
    assert_equal [[1, 2]], rows("WITH q(x) AS (VALUES 1),w AS (WITH q(y) AS (VALUES 2) TABLE q) SELECT q.x,w.y FROM q,w")
    assert_equal [[1]], rows("WITH q(x) AS (WITH q(y) AS (VALUES 1) SELECT y FROM q) TABLE q")
    assert_sql_error 42104, "TABLE q"
    assert_sql_error 42101, "WITH q(x) AS (VALUES 1),q(y) AS (VALUES 2) TABLE q"
    assert_sql_error 42104, "WITH q AS (TABLE later),later AS (VALUES 1) TABLE q"
    assert_sql_error 42121, "WITH q AS (SELECT 1 AS x,2 AS x) TABLE q"
    assert_sql_error 42122, "WITH q AS (SELECT missing) VALUES 1"
  end

  def test_real_tables_take_priority_and_qualified_names_do_not_resolve_ctes
    execute("CREATE TABLE q(x INT)")
    execute("INSERT INTO q VALUES 7")
    assert_equal [[7, 7]], rows("WITH q(x) AS (VALUES 1) SELECT a.x,b.x FROM q a CROSS JOIN PUBLIC.q b")
    assert_sql_error 42102, "WITH missing(x) AS (VALUES 1) TABLE PUBLIC.missing"
  end

  def test_cte_definitions_are_uncorrelated_but_the_body_can_read_outer_columns
    assert_sql_error 42122, "SELECT (WITH q(x) AS (SELECT t.v) TABLE q) AS n FROM (VALUES 1) t(v)"
    assert_equal [[2], [3]], rows("SELECT (WITH q(x) AS (VALUES 1) SELECT t.v+x FROM q) AS n FROM (VALUES 1,2) t(v) ORDER BY n")
    assert_equal [[2]], rows("WITH q(x) AS (VALUES 1) SELECT (WITH q(y) AS (VALUES 2) TABLE q) AS n")
  end

  def test_recursive_queries_evaluate_seed_and_successive_frontiers
    result = execute("WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<4) TABLE r")
    assert_equal ["INTEGER"], result.types.map(&:name)
    assert_equal [[1], [2], [3], [4]], result.rows
    assert_equal [[6]], rows("SELECT SUM(n) FROM (WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3) TABLE r)")
    assert_equal [[1, 1], [2, 2], [3, 3]], rows("WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3) SELECT a.n,b.n FROM r a JOIN r b ON a.n=b.n ORDER BY a.n")
  end

  def test_recursive_set_operator_and_outer_tail_follow_h2_frontier_semantics
    %w[UNION EXCEPT INTERSECT].each do |operator|
      assert_equal [[1], [1], [2], [2], [3], [3]], rows("WITH RECURSIVE r(n) AS (VALUES 1,1 #{operator} SELECT n+1 FROM r WHERE n<3) TABLE r")
    end
    assert_equal [[1], [2], [3]], rows("WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3 ORDER BY 1 DESC LIMIT 1) TABLE r")
  end

  def test_recursive_parameters_are_rebound_for_each_prepared_execution
    statement = @connection.prepare("WITH RECURSIVE r(n) AS (SELECT ? UNION ALL SELECT n+? FROM r WHERE n<?) TABLE r")
    assert_equal [[10], [12], [14]], statement.execute(10, 2, 14).rows
    assert_equal [[100], [103]], statement.execute(100, 3, 103).rows
    assert_equal ["VARCHAR"], statement.execute(10, 2, 14).types.map(&:name)
    assert_sql_error 50004, "WITH q(x) AS (SELECT ?) TABLE q", 1
  end

  def test_recursive_metadata_preserves_raw_seed_values_and_empty_results
    result = execute("WITH RECURSIVE r(n) AS (SELECT '001' UNION ALL SELECT CAST(n AS INT)+1 FROM r WHERE CAST(n AS INT)<3) TABLE r")
    assert_equal ["INTEGER"], result.types.map(&:name)
    assert_equal [["001"], [2], [3]], result.rows
    assert_empty rows("WITH RECURSIVE r(n) AS (SELECT 1 WHERE FALSE UNION ALL SELECT n+1 FROM r WHERE n<3) TABLE r")
  end

  def test_recursive_grammar_requires_columns_and_checks_definition_scopes
    assert_sql_error 42001, "WITH RECURSIVE r AS (VALUES 1) TABLE r"
    assert_sql_error 42104, "WITH r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3) TABLE r"
    assert_sql_error 42001, "WITH RECURSIVE r(n) AS (SELECT n FROM r) TABLE r"
    assert_equal [[1]], rows("WITH RECURSIVE r(n) AS (SELECT n FROM r) VALUES 1")
    assert_sql_error 42001, "WITH RECURSIVE r(n) AS (WITH RECURSIVE q(x) AS (VALUES 1) TABLE q) TABLE r"
    assert_equal [[1]], rows("WITH RECURSIVE r(n) AS (VALUES 1) SELECT n FROM r WHERE n IN(WITH RECURSIVE q(x) AS (VALUES 1) TABLE q)")
  end

  def test_multiple_recursive_ctes_and_nested_nonrecursive_definitions
    assert_equal [[1, 1], [2, 2], [3, 3]], rows("WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3),s(m) AS (SELECT n FROM r) SELECT n,m FROM r JOIN s ON n=m ORDER BY n")
    assert_equal [[1], [2], [3]], rows("WITH RECURSIVE r(n) AS (WITH q(x) AS (VALUES 1) SELECT x FROM q UNION ALL SELECT n+1 FROM r WHERE n<3) TABLE r")
    assert_sql_error 42104, "WITH RECURSIVE r(n) AS (WITH q(x) AS (SELECT n FROM r) SELECT 1 UNION ALL SELECT x+1 FROM q WHERE x<3) TABLE r"
  end

  def test_recursive_hierarchy_uses_current_frontier_in_join_and_string_expressions
    execute("CREATE TABLE folder(id INT PRIMARY KEY,name VARCHAR,parent INT)")
    execute("INSERT INTO folder VALUES(1,NULL,NULL),(2,'bin',1),(3,'docs',1),(4,'html',3)")
    assert_equal [["bin"], ["docs"], ["docs/html"]], rows("WITH RECURSIVE link(id,name,level) AS (SELECT id,name,0 FROM folder WHERE parent IS NULL UNION ALL SELECT f.id,IFNULL(link.name||'/','')||f.name,level+1 FROM link JOIN folder f ON link.id=f.parent) SELECT name FROM link WHERE name IS NOT NULL ORDER BY id")
  end

  def test_original_large_recursive_join_retains_duplicate_frontiers
    execute("CREATE TABLE edges(parent VARCHAR,child VARCHAR)")
    execute("INSERT INTO edges VALUES('/','a'),('a','b1'),('a','b2'),('a','c'),('c','d1'),('c','d2')")
    assert_equal [[29_524]], rows("WITH RECURSIVE r(depth,parent,child) AS (SELECT 0,parent,child FROM edges WHERE parent='/' UNION ALL SELECT depth+1,r.parent,r.child FROM edges i JOIN r ON i.parent=r.child WHERE depth<9) SELECT COUNT(*) FROM r")
    assert_equal [[6]], rows("WITH RECURSIVE r(depth,parent,child) AS (SELECT 0,parent,child FROM edges WHERE parent='/' UNION ALL SELECT depth+1,i.parent,i.child FROM edges i JOIN r ON r.child=i.parent WHERE depth<10) SELECT COUNT(*) FROM r")
  end

  def test_ctes_work_in_create_insert_update_delete_and_transactions
    execute("CREATE TABLE t AS WITH q(x) AS (VALUES 1,2) TABLE q")
    assert_equal 2, execute("INSERT INTO t WITH RECURSIVE r(n) AS (VALUES 3 UNION ALL SELECT n+1 FROM r WHERE n<4) TABLE r").update_count
    execute("BEGIN")
    execute("UPDATE t SET x=(WITH q(y) AS (VALUES 10) TABLE q) WHERE x=1")
    execute("DELETE FROM t WHERE x IN(WITH q(y) AS (VALUES 2) TABLE q)")
    execute("ROLLBACK")
    assert_equal [[1], [2], [3], [4]], rows("TABLE t ORDER BY x")
    assert_sql_error 42001, "WITH q(x) AS (VALUES 1) INSERT INTO t TABLE q"
  end

  def test_saved_recursive_default_reloads_parameters_and_base_data
    Dir.mktmpdir do |directory|
      path = File.join(directory, "ctes")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES 3")
        connection.execute("CREATE TABLE target(v INT DEFAULT (WITH RECURSIVE r(n) AS (SELECT ? UNION ALL SELECT n+1 FROM r WHERE n<(SELECT MAX(v) FROM source)) SELECT MAX(n) FROM r))", 1)
        connection.execute("INSERT INTO target DEFAULT VALUES")
      end
      H2.connect(path: path) do |connection|
        connection.execute("UPDATE source SET v=5")
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [[3], [5]], connection.execute("TABLE target ORDER BY v").rows
        error = assert_raises(H2::Error) { connection.execute("DROP TABLE source") }
        assert_equal 90107, error.code
      end
    end
  end
end

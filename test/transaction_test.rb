# frozen_string_literal: true

require_relative "test_helper"

class TransactionTest < DatabaseTest
  def setup
    super
    execute("CREATE TABLE t(id INT PRIMARY KEY, v INT)")
    execute("INSERT INTO t VALUES (1, 10)")
    @other = @database.connect
  end

  def teardown
    @other.close
    super
  end

  def test_commit_and_rollback
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    assert_equal [[20]], rows("SELECT v FROM t")
    assert_equal [[10]], @other.execute("SELECT v FROM t").rows
    execute("ROLLBACK")
    assert_equal [[10]], rows("SELECT v FROM t")
    execute("BEGIN")
    execute("UPDATE t SET v = 30")
    execute("COMMIT")
    assert_equal [[30]], @other.execute("SELECT v FROM t").rows
  end

  def test_read_committed_sees_later_commits
    execute("BEGIN")
    assert_equal [[10]], rows("SELECT v FROM t")
    @other.execute("UPDATE t SET v = 15")
    assert_equal [[15]], rows("SELECT v FROM t")
  end

  def test_lost_updates_are_rejected
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    @other.execute("UPDATE t SET v = 30")
    assert_sql_error 90131, "COMMIT"
    execute("ROLLBACK")
    assert_equal [[30]], rows("SELECT v FROM t")
  end

  def test_savepoints
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    execute("SAVEPOINT s")
    execute("UPDATE t SET v = 30")
    execute("ROLLBACK TO SAVEPOINT s")
    execute("COMMIT")
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
    assert_sql_error 90063, "ROLLBACK TO SAVEPOINT s"
  end

  def test_statement_error_preserves_prior_transaction_changes
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    assert_sql_error 23505, "INSERT INTO t VALUES (2, 2), (1, 3)"
    execute("COMMIT")
    assert_equal [[1, 20]], @other.execute("TABLE t").rows
  end

  def test_transaction_block_commits_or_rolls_back
    @connection.transaction { |connection| connection.execute("UPDATE t SET v = 20") }
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
    assert_raises(RuntimeError) do
      @connection.transaction do |connection|
        connection.execute("UPDATE t SET v = 30")
        raise "abort"
      end
    end
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
  end

  def test_nested_transaction_uses_savepoint
    @connection.transaction do
      execute("UPDATE t SET v = 20")
      assert_raises(RuntimeError) do
        @connection.transaction do
          execute("UPDATE t SET v = 30")
          raise "nested abort"
        end
      end
      assert_equal [[20]], rows("SELECT v FROM t")
    end
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
  end

  def test_ddl_commits_pending_dml_like_h2
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    execute("CREATE TABLE other_table(a INT)")
    execute("ROLLBACK")
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
    assert_empty @other.execute("TABLE other_table").rows
  end

  def test_autocommit_setting
    execute("SET AUTOCOMMIT FALSE")
    execute("UPDATE t SET v = 20")
    execute("COMMIT")
    execute("UPDATE t SET v = 30")
    assert_equal [[20]], @other.execute("SELECT v FROM t").rows
    execute("SET AUTOCOMMIT TRUE")
    assert_equal [[30]], @other.execute("SELECT v FROM t").rows
  end

  def test_close_rolls_back_and_prepared_statements_check_connection
    statement = @connection.prepare("TABLE t")
    execute("BEGIN")
    execute("UPDATE t SET v = 20")
    @connection.close
    assert_equal [[10]], @other.execute("SELECT v FROM t").rows
    assert_sql_error 90007, "TABLE t"
    assert_raises(H2::Error) { statement.execute }
  end

  def test_connect_block_always_closes
    connection = nil
    H2.connect do |session|
      connection = session
      assert_equal [[1]], session.execute("SELECT 1").rows
    end
    assert connection.closed?
  end
end

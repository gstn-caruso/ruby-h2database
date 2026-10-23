# frozen_string_literal: true

require_relative "test_helper"

class TransactionEdgeTest < DatabaseTest
  def test_nonlocal_exit_rolls_back_transaction_block
    execute("CREATE TABLE t(a INT)")
    catch(:done) do
      @connection.transaction do
        execute("INSERT INTO t VALUES 1")
        throw :done
      end
    end
    assert_empty rows("TABLE t")
    execute("INSERT INTO t VALUES 2")
    assert_equal [[2]], @database.connect { it.execute("TABLE t").rows }
  end

  def test_nested_savepoint_does_not_survive_transaction_rollback
    execute("CREATE TABLE t(a INT)")
    @connection.transaction do
      assert_raises(RuntimeError) do
        @connection.transaction do
          execute("SAVEPOINT nested_point")
          execute("INSERT INTO t VALUES 1")
          raise "abort"
        end
      end
      assert_sql_error 90063, "ROLLBACK TO SAVEPOINT nested_point"
    end
  end

  def test_independent_tables_can_be_committed_concurrently
    execute("CREATE TABLE t(a INT)")
    execute("CREATE TABLE u(a INT)")
    other = @database.connect
    execute("BEGIN")
    other.execute("BEGIN")
    execute("INSERT INTO t VALUES 1")
    other.execute("INSERT INTO u VALUES 2")
    execute("COMMIT")
    other.execute("COMMIT")
    assert_equal [[1]], rows("TABLE t")
    assert_equal [[2]], rows("TABLE u")
  ensure
    other&.close
  end

  def test_multitable_commit_is_atomic_when_one_table_conflicts
    execute("CREATE TABLE t(a INT)")
    execute("CREATE TABLE u(a INT)")
    execute("BEGIN")
    execute("INSERT INTO t VALUES 1")
    execute("INSERT INTO u VALUES 1")
    @database.connect { it.execute("INSERT INTO u VALUES 2") }
    assert_sql_error 90131, "COMMIT"
    execute("ROLLBACK")
    assert_empty rows("TABLE t")
    assert_equal [[2]], rows("TABLE u")
  end

  def test_nested_block_does_not_restore_changes_from_before_an_implicit_commit
    execute("CREATE TABLE t(a INT)")
    @connection.transaction do
      execute("INSERT INTO t VALUES 1")
      assert_raises(RuntimeError) do
        @connection.transaction do
          execute("INSERT INTO t VALUES 2")
          execute("CREATE TABLE u(a INT)")
          execute("INSERT INTO t VALUES 3")
          raise "abort after DDL"
        end
      end
      assert_equal [[1], [2]], rows("TABLE t")
      execute("INSERT INTO t VALUES 4")
    end
    assert_equal [[1], [2], [4]], @database.connect { it.execute("TABLE t").rows }
  end
end

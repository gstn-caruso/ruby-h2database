# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class SessionTemporalTest < DatabaseTest
  def with_clock
    instant = Time.new(2000, 2, 28, 23, 59, Rational(59_123_456_789, 1_000_000_000))
    original = Time.method(:now)
    Time.singleton_class.remove_method(:now)
    Time.define_singleton_method(:now) { instant }
    yield ->(value) { instant = value }
  ensure
    Time.singleton_class.remove_method(:now)
    Time.define_singleton_method(:now, original)
  end

  def test_current_local_values_use_one_statement_instant_and_declared_scales
    with_clock do
      result = execute("SELECT CURRENT_DATE(),LOCALTIME,LOCALTIME(9),LOCALTIMESTAMP,LOCALTIMESTAMP(9),CURDATE(),CURTIME(),NOW(3)")
      assert_equal ["CURRENT_DATE", "LOCALTIME", "LOCALTIME(9)", "LOCALTIMESTAMP", "LOCALTIMESTAMP(9)", "CURRENT_DATE", "LOCALTIME", "LOCALTIMESTAMP(3)"], result.columns
      assert_equal [["DATE", 10, 0], ["TIME", 8, 0], ["TIME", 18, 9], ["TIMESTAMP", 26, 6], ["TIMESTAMP", 29, 9], ["DATE", 10, 0], ["TIME", 8, 0], ["TIMESTAMP", 23, 3]], result.types.map { [it.name, it.precision, it.scale] }
      assert_equal [["2000-02-28", "23:59:59", "23:59:59.123456789", "2000-02-28 23:59:59.123457", "2000-02-28 23:59:59.123456789", "2000-02-28", "23:59:59", "2000-02-28 23:59:59.123"]], result.rows.map { it.map(&:to_s) }
      assert_equal [[true, true]], rows("SELECT LOCALTIME(9)=CAST(LOCALTIMESTAMP(9) AS TIME(9)),CURRENT_DATE=CAST(LOCALTIMESTAMP(9) AS DATE)")
    end
  end

  def test_reused_statements_refresh_in_autocommit_and_hold_during_transactions
    statement = @connection.prepare("SELECT LOCALTIMESTAMP(9)")
    with_clock do |advance|
      first = statement.execute.rows.first.first
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      refute_equal first, statement.execute.rows.first.first
      execute("BEGIN")
      start = statement.execute.rows.first.first
      advance.call(Time.new(2000, 3, 1, 4, 5, 6))
      assert_equal start, statement.execute.rows.first.first
      assert_equal [[H2::DateValue.parse("2000-02-29")]], rows("SELECT CURRENT_DATE")
      execute("COMMIT")
      refute_equal start, statement.execute.rows.first.first
    end
  end

  def test_begin_does_not_capture_the_clock_until_a_value_is_requested
    with_clock do |advance|
      execute("BEGIN")
      execute("SELECT 1")
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      assert_equal [["2000-02-29 01:02:03"]], rows("SELECT LOCALTIMESTAMP").map { it.map(&:to_s) }
    end
  end

  def test_connection_clocks_are_independent_and_rollback_releases_the_snapshot
    other = @database.connect
    with_clock do |advance|
      execute("SET AUTOCOMMIT FALSE")
      first = rows("SELECT LOCALTIMESTAMP(9)")
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      refute_equal first, other.execute("SELECT LOCALTIMESTAMP(9)").rows
      assert_equal first, rows("SELECT LOCALTIMESTAMP(9)")
      execute("SAVEPOINT before")
      assert_equal first, rows("SELECT LOCALTIMESTAMP(9)")
      execute("ROLLBACK TO SAVEPOINT before")
      refute_equal first, rows("SELECT LOCALTIMESTAMP(9)")
      second = rows("SELECT LOCALTIMESTAMP(9)")
      advance.call(Time.new(2000, 3, 1, 4, 5, 6))
      execute("ROLLBACK")
      refute_equal second, rows("SELECT LOCALTIMESTAMP(9)")
    end
  ensure
    other&.close
  end

  def test_rounding_can_cross_midnight_without_changing_current_date
    with_clock do |advance|
      advance.call(Time.new(2000, 2, 28, 23, 59, Rational(59_999_999_999, 1_000_000_000)))
      assert_equal [["2000-02-28", "23:59:59", "2000-02-29 00:00:00"]], rows("SELECT CURRENT_DATE,LOCALTIME,LOCALTIMESTAMP(0)").map { it.map(&:to_s) }
    end
  end

  def test_transaction_blocks_release_clocks_and_nested_failures_refresh_them
    with_clock do |advance|
      @connection.transaction do
        first = rows("SELECT LOCALTIMESTAMP(9)")
        advance.call(Time.new(2000, 2, 29, 1, 2, 3))
        assert_equal first, rows("SELECT LOCALTIMESTAMP(9)")
        assert_raises(RuntimeError) do
          @connection.transaction { raise "restore nested savepoint" }
        end
        refute_equal first, rows("SELECT LOCALTIMESTAMP(9)")
        advance.call(Time.new(2000, 3, 1, 4, 5, 6))
        assert_equal [[H2::DateValue.parse("2000-02-29")]], rows("SELECT CURRENT_DATE")
      end
      assert_equal [[H2::DateValue.parse("2000-03-01")]], rows("SELECT CURRENT_DATE")
    end
  end

  def test_failed_native_commit_releases_the_clock_before_publication
    other = @database.connect
    execute("CREATE TABLE versions(v INT)")
    execute("INSERT INTO versions VALUES(0)")
    with_clock do |advance|
      execute("BEGIN")
      execute("UPDATE versions SET v=1")
      rows("SELECT CURRENT_DATE")
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      other.execute("UPDATE versions SET v=2")
      error = assert_raises(H2::Error) { @connection.commit }
      assert_equal 90131, error.code
      assert_equal [[H2::DateValue.parse("2000-02-29")]], rows("SELECT CURRENT_DATE")
    end
  ensure
    other&.close
  end

  def test_time_to_timestamp_casts_and_assignment_use_the_current_session_date
    execute("CREATE TABLE t(ts TIMESTAMP(9) DEFAULT TIME '01:02:03.123456789')")
    with_clock do
      execute("INSERT INTO t VALUES(DEFAULT),(TIME '04:05:06.123456789')")
      assert_equal [["2000-02-28 01:02:03.123456789"], ["2000-02-28 04:05:06.123456789"]], rows("TABLE t").map { it.map(&:to_s) }
      assert_equal [["2000-02-28 12:00:00.123457"]], rows("SELECT CAST(TIME '12:00:00.123456789' AS TIMESTAMP)").map { it.map(&:to_s) }
      assert_equal [["2000-02-28 02:00:00"]], rows("VALUES COALESCE(NULL,TIME '02:00:00',TIMESTAMP '1900-01-01 00:00:00')").map { it.map(&:to_s) }
      assert_equal [["2000-02-28 02:00:00"]], rows("VALUES TIME '02:00:00' UNION SELECT TIMESTAMP '2000-02-28 02:00:00'").map { it.map(&:to_s) }
    end
  end

  def test_context_flows_through_ctes_subqueries_row_casts_and_updates
    with_clock do
      assert_equal [[true]], rows("WITH x AS (SELECT CAST(TIME '12:00:00' AS TIMESTAMP) AS ts) SELECT ts=(SELECT CAST(CURRENT_DATE AS TIMESTAMP)+TIME '12:00:00') FROM x")
      value = rows("SELECT ROW(CAST(TIME '12:00:00' AS TIMESTAMP),1)").first.first
      assert_equal "2000-02-28 12:00:00", value.values.first.to_s
      execute("CREATE TABLE t(ts TIMESTAMP)")
      execute("INSERT INTO t VALUES(NULL)")
      execute("UPDATE t SET ts=TIME '13:00:00'")
      assert_equal [["2000-02-28 13:00:00"]], rows("TABLE t").map { it.map(&:to_s) }
    end
  end

  def test_errors_keep_transaction_clock_but_ddl_and_failed_savepoint_rollback_reset_it
    with_clock do |advance|
      execute("BEGIN")
      first = rows("SELECT LOCALTIMESTAMP(9)")
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      assert_sql_error 22012, "SELECT 1/0"
      assert_equal first, rows("SELECT LOCALTIMESTAMP(9)")
      assert_sql_error 90063, "ROLLBACK TO SAVEPOINT missing"
      second = rows("SELECT LOCALTIMESTAMP(9)")
      refute_equal first, second
      advance.call(Time.new(2000, 3, 1, 4, 5, 6))
      execute("CREATE TABLE reset_clock(v INT)")
      refute_equal second, rows("SELECT LOCALTIMESTAMP(9)")
    end
  end

  def test_year_month_differences_promote_only_time_operands_to_the_session_date
    with_clock do
      assert_equal [["INTERVAL '1' MONTH", "INTERVAL '-1' MONTH"]], rows("SELECT (TIME '12:00:00'-TIMESTAMP '2000-01-28 12:00:00') MONTH,(TIMESTAMP '2000-01-28 12:00:00'-TIME '12:00:00') MONTH").map { it.map(&:to_s) }
      assert_sql_error 22018, "SELECT (TIME '12:00:00'-TIME '11:00:00') MONTH"
      assert_equal [["INTERVAL '-1' MONTH"]], rows("SELECT (CURRENT_DATE-TIME '12:00:00') MONTH").map { it.map(&:to_s) }
      assert_equal [["INTERVAL '11014 12:00:00' DAY TO SECOND"]], rows("SELECT DATE '2000-02-28'-TIME '12:00:00'").map { it.map(&:to_s) }
    end
  end

  def test_saved_defaults_evaluate_at_insert_time_including_after_reopen
    Dir.mktmpdir do |directory|
      path = File.join(directory, "clock.mv.db")
      with_clock do |advance|
        H2.connect(path: path) do |connection|
          connection.execute("CREATE TABLE t(d DATE DEFAULT CURRENT_DATE,ts TIMESTAMP(9) DEFAULT LOCALTIMESTAMP(9),promoted TIMESTAMP DEFAULT CAST(TIME '12:00:00' AS TIMESTAMP))")
          advance.call(Time.new(2000, 2, 29, 1, 2, 3))
          connection.execute("INSERT INTO t DEFAULT VALUES")
        end
        advance.call(Time.new(2000, 3, 1, 4, 5, 6))
        H2.connect(path: path) do |connection|
          connection.execute("INSERT INTO t DEFAULT VALUES")
          assert_equal [["2000-02-29", "2000-02-29 01:02:03", "2000-02-29 12:00:00"], ["2000-03-01", "2000-03-01 04:05:06", "2000-03-01 12:00:00"]], connection.execute("TABLE t ORDER BY d").rows.map { it.map(&:to_s) }
        end
      end
    end
  end

  def test_dynamic_defaults_and_subqueries_do_not_freeze_session_values
    with_clock do |advance|
      execute("CREATE TABLE t(d DATE DEFAULT (SELECT CURRENT_DATE),ts TIMESTAMP DEFAULT DATE_TRUNC(DAY,CAST(TIME '12:00:00' AS TIMESTAMP)))")
      insert = @connection.prepare("INSERT INTO t DEFAULT VALUES")
      insert.execute
      advance.call(Time.new(2000, 2, 29, 1, 2, 3))
      insert.execute
      assert_equal [["2000-02-28", "2000-02-28 00:00:00"], ["2000-02-29", "2000-02-29 00:00:00"]], rows("TABLE t ORDER BY d").map { it.map(&:to_s) }
    end
  end

  def test_current_function_precision_errors_and_unported_zoned_functions
    assert_sql_error 42001, "SELECT CURRENT_DATE(1)"
    assert_sql_error 90151, "SELECT LOCALTIME(-1)"
    assert_sql_error 90151, "SELECT NOW(10)"
    assert_sql_error 50100, "SELECT CURRENT_TIMESTAMP"
    assert_sql_error 50100, "SELECT CURRENT_TIME"
    assert_sql_error 42122, "SELECT CURDATE"
  end
end

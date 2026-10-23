# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DateFunctionsTest < DatabaseTest
  def test_dateadd_clamps_calendar_months_and_years_without_losing_nanoseconds
    assert_equal [["2000-02-29 10:20:30.123456789", "1999-02-28", "1999-12-31", "3000-02-28"]], text_rows("SELECT DATEADD(month,1,TIMESTAMP '2000-01-31 10:20:30.123456789'),DATEADD(year,-1,DATE '2000-02-29'),DATEADD(month,-1,DATE '2000-01-31'),DATEADD(millennium,1,DATE '2000-02-29')")
  end

  def test_dateadd_wraps_time_and_promotes_dates_for_subday_fields
    assert_equal [["00:00:00.000000001", "1999-12-31 23:59:59.999999999", "2000-03-07"]], text_rows("SELECT DATEADD(ns,1,TIME '00:00:00'),DATEADD(ns,-1,DATE '2000-01-01'),TIMESTAMPADD(SQL_TSI_WEEK,1,DATE '2000-02-29')")
    assert_equal [["00:00:00", "23:59:59.999999999"]], text_rows("SELECT DATEADD(hour,1,TIME '23:00:00'),DATEADD(ns,-1,TIME '00:00:00')")
    assert_sql_error 90008, "SELECT DATEADD(day,1,TIME '12:00:00')"
  end

  def test_dateadd_converts_counts_with_h2_rounding_and_range_checks
    assert_equal [["2000-01-02", "1999-12-31", "2000-01-01", "2000-01-02"]], text_rows("SELECT DATEADD(day,0.5,DATE '2000-01-01'),DATEADD(day,-0.5,DATE '2000-01-01'),DATEADD(day,CAST(-0.5 AS DOUBLE),DATE '2000-01-01'),DATEADD(day,TRUE,DATE '2000-01-01')")
    assert_sql_error 22018, "SELECT DATEADD(day,'0.5',DATE '2000-01-01')"
    assert_sql_error 22018, "SELECT DATEADD(day,'1_0',DATE '2000-01-01')"
    assert_sql_error 90008, "SELECT DATEADD(day,2147483648,DATE '2000-01-01')"
    assert_sql_error 22003, "SELECT DATEADD(ns,9223372036854775808,TIME '00:00:00')"
  end

  def test_datediff_counts_crossed_units_in_both_directions
    assert_equal [[1, 1, 1, 1, 1, 1, 1, -1]], rows("SELECT DATEDIFF(year,'1999-12-31 23:59:59.999999999','2000-01-01'),DATEDIFF(month,'1999-12-31 23:59:59.999999999','2000-01-01'),DATEDIFF(day,'1999-12-31 23:59:59.999999999','2000-01-01'),DATEDIFF(hour,'1999-12-31 23:59:59.999999999','2000-01-01'),DATEDIFF(second,'1999-12-31 23:59:59.999999999','2000-01-01'),DATEDIFF(ns,'1999-12-31 23:59:59.999999999','2000-01-01'),TIMESTAMPDIFF(quarter,'1999-12-31','2000-01-01'),DATEDIFF(second,'2000-01-01','1999-12-31 23:59:59.999999999')")
    assert_equal [[0, 1, -1]], rows("SELECT DATEDIFF(ms,TIME '00:00:00.000000001',TIME '00:00:00.000999999'),DATEDIFF(iso_week,DATE '1969-12-28',DATE '1969-12-29'),DATEDIFF(iso_week,DATE '1969-12-29',DATE '1969-12-28')")
  end

  def test_negative_year_periods_and_java_integer_overflow
    assert_equal [[1, 1, 1]], rows("SELECT DATEDIFF(century,DATE '-0100-12-31',DATE '-0099-01-01'),DATEDIFF(millennium,DATE '0000-12-31',DATE '0001-01-01'),DATEDIFF(decade,DATE '-0001-12-31',DATE '0000-01-01')")
    assert_equal [["-1000-01-01"]], text_rows("SELECT DATEADD(millennium,2147483647,DATE '0000-01-01')")
    assert_equal [[-7_503_182_744_413_601_792]], rows("SELECT DATEDIFF(ns,DATE '-1000000000-01-01',DATE '1000000000-12-31')")
    assert_sql_error 50000, "SELECT DATEADD(year,1,DATE '1000000000-12-31')"
    assert_equal [[-884_901_888]], rows("SELECT DATEDIFF(month,DATE '-1000000000-01-01',DATE '0000-01-01')")
    assert_sql_error 50000, "SELECT DATEADD(ns,-9223372036854775808,DATE '2000-01-01')"
    assert_sql_error 22007, "SELECT DATEADD(ns,9223372036854775807,TIME '23:59:59.999999999')"
  end

  def test_fields_are_static_and_nulls_retain_result_types
    result = execute("SELECT DATEADD(day,NULL,DATE '2000-01-01'),DATEDIFF(day,NULL,NULL)")
    assert_equal [[nil, nil]], result.rows
    assert_equal %w[DATE BIGINT], result.types.map(&:name)
    assert_equal ["CAST(NULL AS DATE)", "CAST(NULL AS BIGINT)"], result.columns
    assert_sql_error 90008, "SELECT DATEADD('bad',NULL,NULL)"
    assert_sql_error 42001, "SELECT DATEADD(?,1,DATE '2000-01-01')", "DAY"
    assert_sql_error 90008, "SELECT DATEADD(day,1,TIME '12:00:00') WHERE FALSE"
    assert_sql_error 50100, "SELECT DATEDIFF(timezone_hour,DATE '2000-01-01',DATE '2000-01-02')"
  end

  def test_parameters_and_dynamic_saved_defaults_preserve_function_fields
    Dir.mktmpdir do |directory|
      path = File.join(directory, "dates")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(d DATE)")
        connection.execute("INSERT INTO source VALUES(DATE '2000-01-31')")
        connection.execute("CREATE TABLE target(d DATE DEFAULT DATEADD(month,?,(SELECT MAX(d) FROM source)),n BIGINT DEFAULT DATEDIFF(day,DATE '2000-01-01',(SELECT MAX(d) FROM source)))", 1)
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO target DEFAULT VALUES")
        connection.execute("UPDATE source SET d=DATE '2000-02-29'")
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [["2000-02-29", "30"], ["2000-03-29", "59"]], connection.execute("TABLE target ORDER BY d").rows.map { it.map(&:to_s) }
        statement = connection.prepare("SELECT DATEADD(day,?,CAST(? AS DATE)),DATEDIFF(month,CAST(? AS DATE),CAST(? AS DATE))")
        assert_equal [["2000-03-01", "2"]], statement.execute(1, "2000-02-29", "1999-12-31", "2000-02-01").rows.map { it.map(&:to_s) }
      end
    end
  end

  private

  def text_rows(sql)
    rows(sql).map { it.map(&:to_s) }
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class CalendarFunctionsTest < DatabaseTest
  def test_truncation_discards_fractional_fields_and_retains_value_kinds
    result = execute("SELECT DATE_TRUNC(mcs,TIME '12:34:56.123456789'),DATE_TRUNC(hour,TIMESTAMP '2000-02-29 12:34:56.123456789'),DATE_TRUNC(month,DATE '2000-02-29')")
    assert_equal %w[TIME TIMESTAMP DATE], result.types.map(&:name)
    assert_equal [["12:34:56.123456", "2000-02-29 12:00:00", "2000-02-01"]], texts(result)
    assert_equal [["00:00:00"]], texts(execute("SELECT DATE_TRUNC(year,TIME '12:34:56.123456789')"))
  end

  def test_week_years_handle_iso_boundaries_and_the_initial_sunday_calendar
    assert_equal [[2015, 53, 5, 2016, 1]], rows("SELECT ISO_YEAR(DATE '2016-01-01'),ISO_WEEK(DATE '2016-01-01'),ISO_DAY_OF_WEEK(DATE '2016-01-01'),EXTRACT(week_year FROM DATE '2016-01-01'),WEEK(DATE '2016-01-01')")
    assert_equal [["2016-01-04 00:00:00", "2017-01-01 12:34:56.123456789", "2016-12-26", "2017-01-01"]], texts(execute("SELECT DATE_TRUNC(iso_week_year,TIMESTAMP '2017-01-01 12:34:56.123456789'),DATE_TRUNC(week_year,TIMESTAMP '2017-01-01 12:34:56.123456789'),DATE_TRUNC(iso_week,DATE '2017-01-01'),DATE_TRUNC(week,DATE '2017-01-01')"))
  end

  def test_periods_normalize_year_zero_and_negative_years
    assert_equal [["-0010-01-01", "-0099-01-01", "-0999-01-01"]], texts(execute("SELECT DATE_TRUNC(decade,DATE '-0001-12-31'),DATE_TRUNC(century,DATE '0000-12-31'),DATE_TRUNC(millennium,DATE '-0999-01-01')"))
    assert_equal [[-1, 0, 0]], rows("SELECT EXTRACT(decade FROM DATE '-0001-12-31'),EXTRACT(century FROM DATE '-0099-01-01'),EXTRACT(millennium FROM DATE '0000-12-31')")
    assert_sql_error 50000, "SELECT DATE_TRUNC(century,DATE '-1000000000-01-01')"
  end

  def test_epoch_preserves_fractional_seconds_and_wide_years
    result = execute("SELECT EXTRACT(epoch FROM TIMESTAMP '1969-12-31 23:59:59.999999999'),EXTRACT(epoch FROM TIME '01:00:00.123456789'),EXTRACT(epoch FROM DATE '-1000000000-01-01')")
    assert_equal [[BigDecimal('-0.000000001'), BigDecimal('3600.123456789'), BigDecimal('-31557014167219200')]], result.rows
    assert_equal %w[NUMERIC NUMERIC NUMERIC], result.types.map(&:name)
    assert_equal [[2000, 123456789]], rows("SELECT EXTRACT('yyyy' FROM DATE '2000-01-01'),EXTRACT(ns FROM TIME '12:34:56.123456789')")
  end

  def test_last_day_handles_leap_centuries_timestamps_and_text
    assert_equal [["1900-02-28", "2000-02-29", "0000-02-29", "2024-04-30"]], texts(execute("SELECT LAST_DAY(DATE '1900-02-01'),LAST_DAY(TIMESTAMP '2000-02-01 23:59:59.999999999'),LAST_DAY('0000-02-01'),LAST_DAY('2024-04-01 12:34:56')"))
    assert_sql_error 50000, "SELECT LAST_DAY('bad')"
    assert_sql_error 50000, "SELECT LAST_DAY(TIME '12:34:56')"
    assert_equal [[H2::DateValue.parse("2000-01-31")]], rows("SELECT LAST_DAY('2000-01-01 12:00:00+03:00')")
  end

  def test_static_type_checks_nulls_labels_and_declared_scales
    assert_sql_error 90008, "SELECT DATE_TRUNC(day,'2000-01-01') WHERE FALSE"
    assert_sql_error 90008, "SELECT DATE_TRUNC(day,NULL)"
    assert_sql_error 50100, "SELECT DATE_TRUNC(ns,TIME '12:34:56')"
    assert_sql_error 90008, "SELECT EXTRACT(day_of_month FROM DATE '2000-01-01')"
    execute("SET TIME ZONE '+03'")
    assert_equal [[3]], rows("SELECT EXTRACT(timezone_hour FROM DATE '2000-01-01')")
    result = execute("SELECT DATE_TRUNC(day,CAST(NULL AS TIME(3))),LAST_DAY(NULL),EXTRACT(epoch FROM CAST(NULL AS DATE))")
    assert_equal [[nil, nil, nil]], result.rows
    assert_equal ["CAST(NULL AS TIME(3))", "CAST(NULL AS DATE)", "CAST(NULL AS NUMERIC(28, 9))"], result.columns
    assert_equal [3, 0, 9], result.types.map(&:scale)
  end

  def test_calendar_defaults_remain_dynamic_after_file_reopen
    Dir.mktmpdir do |directory|
      path = File.join(directory, "calendar")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(d DATE)")
        connection.execute("INSERT INTO source VALUES(DATE '2000-02-15')")
        connection.execute("CREATE TABLE target(first_day DATE DEFAULT DATE_TRUNC(month,(SELECT MAX(d) FROM source)),last_day DATE DEFAULT LAST_DAY((SELECT MAX(d) FROM source)),week INT DEFAULT EXTRACT(iso_week FROM (SELECT MAX(d) FROM source)),epoch NUMERIC(28,9) DEFAULT EXTRACT(epoch FROM (SELECT MAX(d) FROM source)))")
      end
      H2.connect(path: path) do |connection|
        connection.execute("UPDATE source SET d=DATE '2016-01-01'")
        connection.execute("INSERT INTO target DEFAULT VALUES")
        assert_equal [["2016-01-01", "2016-01-31", "53", "1451606400.0"]], texts(connection.execute("TABLE target"))
        statement = connection.prepare("SELECT DATE_TRUNC(mcs,CAST(? AS TIMESTAMP(9))),LAST_DAY(?),EXTRACT(iso_year FROM CAST(? AS DATE))")
        assert_equal [["2000-02-29 12:34:56.123456", "2000-02-29", "2015"]], texts(statement.execute("2000-02-29 12:34:56.123456789", "2000-02-01", "2016-01-01"))
      end
    end
  end

  private

  def texts(result)
    result.rows.map { it.map { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value.to_s } }
  end
end

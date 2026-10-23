# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "date"

class TemporalTest < DatabaseTest
  def test_typed_literals_parse_gregorian_and_compatibility_formats
    result = execute("SELECT DATE '20000102' AS d,TIME '112233.1234567899' AS t,TIMESTAMP '20000102T112233.123456789' AS ts")
    assert_equal %w[DATE TIME TIMESTAMP], result.types.map(&:name)
    assert_equal [[H2::DateValue.parse("2000-01-02"), H2::TimeValue.parse("11:22:33.123456789"), H2::TimestampValue.parse("2000-01-02 11:22:33.123456789")]], result.rows
    assert_equal [["-0100-01-02", "0300-12-31", "11:22:33.1"]], rows("SELECT CAST(DATE '-1000102' AS VARCHAR),CAST(DATE '3001231' AS VARCHAR),CAST(TIME '11.22.33.1' AS VARCHAR)")
    assert_sql_error 22007, "SELECT DATE '1900-02-29'"
    assert_sql_error 22007, "SELECT TIME '24:00:00'"
    assert_sql_error 22007, "SELECT TIME '-1:00:00'"
    assert_sql_error 22007, "SELECT TIME '12-2:00'"
    assert_sql_error 22007, "SELECT TIMESTAMP '2000-01-02 11:60:00'"
  end

  def test_date_values_cover_h2_year_range_and_packed_calendar_roundtrips
    [-1_000_000_000, -400, -1, 0, 1, 1900, 2000, 1_000_000_000].each do |year|
      value = H2::DateValue.new(year, 3, 1)
      assert_equal value, H2::DateValue.from_days(value.absolute_day)
      assert_equal value, H2::DateValue.from_packed(value.packed)
      assert_equal value, H2::DateValue.parse(value.to_s)
    end
    assert_sql_error 22007, "SELECT DATE '1000000001-01-01'"
    assert_sql_error 22007, "SELECT DATE '-1000000001-12-31'"
  end

  def test_assignment_rounds_fractional_seconds_and_explicit_precision_is_validated
    execute("CREATE TABLE t(t TIME,t8 TIME(8),ts TIMESTAMP,ts0 TIMESTAMP(0),ts9 TIMESTAMP(9) WITHOUT TIME ZONE)")
    execute("INSERT INTO t VALUES('23:59:59.999999999','23:59:59.999999999','2000-01-01 08:00:00.123456789','2000-01-01 23:59:59.999999999','2000-01-01 08:00:00.123456789')")
    assert_equal [["23:59:59", "23:59:59.99999999", "2000-01-01 08:00:00.123457", "2000-01-02 00:00:00", "2000-01-01 08:00:00.123456789"]], rows("TABLE t").map { |row| row.map(&:to_s) }
    assert_sql_error 90151, "CREATE TABLE bad(t TIME(10))"
    assert_sql_error 90008, "SELECT CAST('00:00:00' AS TIME(-1))"
    assert_equal [["1000000000-12-31 23:59:59.999999"]], rows("SELECT CAST(TIMESTAMP '1000000000-12-31 23:59:59.999999999' AS TIMESTAMP)").map { |row| row.map(&:to_s) }
  end

  def test_date_time_and_timestamp_casts_preserve_the_supported_components
    assert_equal [["2000-01-02", "11:22:33", "11:22:33.123456789", "2000-01-02 00:00:00"]], rows("SELECT CAST(TIMESTAMP '2000-01-02 11:22:33.123456789' AS DATE),CAST(TIMESTAMP '2000-01-02 11:22:33.123456789' AS TIME),CAST(TIMESTAMP '2000-01-02 11:22:33.123456789' AS TIME(9)),CAST(DATE '2000-01-02' AS TIMESTAMP)").map { |row| row.map(&:to_s) }
    assert_sql_error 22018, "SELECT CAST(DATE '2000-01-01' AS TIME)"
    assert_sql_error 22018, "SELECT CAST(TIME '10:00:00' AS DATE)"
    assert_equal [[H2::DateValue.parse("2000-01-01")]], rows("SELECT CAST(' 2000-01-01 ' AS DATE)")
  end

  def test_comparisons_keys_and_sets_use_temporal_values_without_rounding
    execute("CREATE TABLE dates(d DATE PRIMARY KEY,ts TIMESTAMP(9))")
    execute("INSERT INTO dates VALUES('2000-01-01','2000-01-01 00:00:00'),('1999-12-31','2000-01-01 00:00:00.000000001')")
    assert_equal [[true]], rows("SELECT DATE '2000-01-01'=TIMESTAMP '2000-01-01 00:00:00'")
    assert_equal [[H2::DateValue.parse("2000-01-01")]], rows("SELECT d FROM dates WHERE d='2000-01-01'")
    assert_sql_error 23505, "INSERT INTO dates VALUES('20000101',NULL)"
    assert_sql_error 90110, "SELECT DATE '2000-01-01'=TIME '00:00:00'"
    assert_sql_error 90110, "SELECT DATE '2000-01-01'=1"
    assert_equal [[H2::TimeValue.parse("12:00:00.000000001")]], rows("VALUES TIME '12:00:00.000000001' UNION VALUES TIME '12:00:00.000000001'")
    assert_equal [[H2::TimestampValue.parse("2000-01-01 00:00:00")]], rows("SELECT DATE '2000-01-01' AS d UNION SELECT TIMESTAMP '2000-01-01 00:00:00'")
  end

  def test_calendar_and_time_arithmetic
    assert_equal [["2000-02-29", "2000-03-01", "2000-01-01 12:34:56.123456789", "2000-01-02 01:00:00", "01:00:00", "00:30:00"]], rows("SELECT DATE '2000-02-28'+1,DATE '2000-02-29'+1,DATE '2000-01-01'+TIME '12:34:56.123456789',TIMESTAMP '2000-01-01 23:00:00'+TIME '02:00:00',TIME '23:00:00'+TIME '02:00:00',TIME '01:00:00'/2").map { |row| row.map(&:to_s) }
    assert_equal [["2000-01-01 12:00:00"]], rows("SELECT DATE '2000-01-01'+0.5").map { |row| row.map(&:to_s) }
    assert_sql_error 22007, "SELECT TIME '01:00:00'/0"
    assert_sql_error 50100, "SELECT DATE '2000-01-01'+CAST(1 AS BIGINT)"
  end

  def test_extract_and_calendar_aliases
    assert_equal [[2024, 2, 29, 5, 60, 1, 12, 34, 56, 123, 123456, 123456789]], rows("SELECT EXTRACT(YEAR FROM DATE '2024-02-29'),MONTH(DATE '2024-02-29'),DAY_OF_MONTH(DATE '2024-02-29'),DAY_OF_WEEK(DATE '2024-02-29'),DAY_OF_YEAR(DATE '2024-02-29'),QUARTER(DATE '2024-02-29'),HOUR(TIME '12:34:56.123456789'),MINUTE(TIME '12:34:56.123456789'),SECOND(TIME '12:34:56.123456789'),EXTRACT(MILLISECOND FROM TIME '12:34:56.123456789'),EXTRACT(MICROSECOND FROM TIME '12:34:56.123456789'),EXTRACT(NANOSECOND FROM TIME '12:34:56.123456789')")
  end

  def test_parameters_copy_ruby_wall_clock_components_and_accept_native_values
    timestamp = Time.new(2000, 1, 2, 3, 4, Rational(5_123_456_789, 1_000_000_000), "+03:00")
    datetime = DateTime.new(2000, 1, 2, 3, 4, Rational(5_123_456_789, 1_000_000_000), Rational(-3, 24))
    result = execute("SELECT ?,?,?,?", Date.new(2000, 2, 29), timestamp, H2::TimeValue.parse("12:00:00.123456789"), datetime)
    assert_equal %w[DATE TIMESTAMP TIME TIMESTAMP], result.types.map(&:name)
    assert_equal [["2000-02-29", "2000-01-02 03:04:05.123456789", "12:00:00.123456789", "2000-01-02 03:04:05.123456789"]], result.rows.map { |row| row.map(&:to_s) }
  end

  def test_temporal_rows_defaults_indexes_and_precisions_survive_reopen
    Dir.mktmpdir do |directory|
      path = File.join(directory, "temporal")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(d DATE PRIMARY KEY DEFAULT DATE '2000-02-29',t TIME(9) UNIQUE DEFAULT TIME '12:34:56.123456789',ts TIMESTAMP(9) DEFAULT TIMESTAMP '-1000000000-01-01 00:00:00')")
        connection.execute("INSERT INTO t DEFAULT VALUES")
        connection.execute("CREATE TABLE r AS SELECT ROW(DATE '2000-01-01',TIME '23:00:00.123456789') AS pair")
      end
      H2.connect(path: path) do |connection|
        assert_equal [["2000-02-29", "12:34:56.123456789", "-1000000000-01-01 00:00:00"]], connection.execute("TABLE t").rows.map { |row| row.map(&:to_s) }
        assert_equal [0, 9, 9], connection.execute("TABLE t").types.map(&:scale)
        assert_equal [[H2::RowValue.new([H2::DateValue.parse("2000-01-01"), H2::TimeValue.parse("23:00:00.123456789")])]], connection.execute("TABLE r").rows
      end
    end
  end

  def test_remaining_zone_and_session_date_conversions_fail_explicitly
    assert_sql_error 50100, "SELECT TIME '12:00:00Z'"
    assert_sql_error 50100, "SELECT TIMESTAMP '2000-01-01 12:00:00+03:00'"
    assert_sql_error 50100, "CREATE TABLE zoned(t TIMESTAMP WITH TIME ZONE)"
    assert_sql_error 50100, "SELECT CAST(TIME '12:00:00' AS TIMESTAMP)"
  end
end

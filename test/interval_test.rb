# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class IntervalTest < DatabaseTest
  def test_literals_preserve_all_qualifiers_and_normalize_signs_and_fields
    qualifiers = %w[YEAR MONTH DAY HOUR MINUTE SECOND] + ["YEAR TO MONTH", "DAY TO HOUR", "DAY TO MINUTE", "DAY TO SECOND", "HOUR TO MINUTE", "HOUR TO SECOND", "MINUTE TO SECOND"]
    texts = ["1", "1", "1", "1", "1", "1.123456789", "1-2", "1 2", "1 2:3", "1 2:3:4.123456789", "1:2", "1:2:3.123456789", "1:2.123456789"]
    qualifiers.zip(texts).each do |qualifier, text|
      result = execute("SELECT INTERVAL '#{text}' #{qualifier}")
      assert_equal "INTERVAL #{qualifier}", result.types.first.name
      assert_equal qualifier, result.rows.first.first.qualifier
      assert_equal result.rows.first.first, H2::IntervalValue.parse(qualifier, text)
    end
    assert_equal [["INTERVAL '0' DAY", "INTERVAL '0.1' SECOND", "INTERVAL '-0.1' SECOND"]], strings("SELECT INTERVAL '-0' DAY,INTERVAL -'-0.1' SECOND,INTERVAL '-0.1' SECOND")
    year = H2::IntervalValue.parse("YEAR", "1")
    months = H2::IntervalValue.parse("MONTH", "12")
    refute_equal year, months
    refute_equal year, H2::IntervalValue.parse("DAY", "1")
    assert_equal 0, year <=> months
  end

  def test_calendar_and_clock_conversions_truncate_lower_units
    assert_equal [["INTERVAL '-120' MONTH", "INTERVAL '-1' YEAR", "INTERVAL '-1-8' YEAR TO MONTH", "INTERVAL '-1 02' DAY TO HOUR"]], strings("SELECT CAST(INTERVAL '-10' YEAR AS INTERVAL MONTH(3)),CAST(INTERVAL '-20' MONTH AS INTERVAL YEAR),CAST(INTERVAL '-20' MONTH AS INTERVAL YEAR TO MONTH),CAST(INTERVAL '-93784.123456789' SECOND AS INTERVAL DAY TO HOUR)")
    assert_sql_error 22018, "SELECT CAST(INTERVAL '1' YEAR AS INTERVAL DAY)"
    assert_sql_error 22007, "SELECT CAST('INTERVAL ''1'' YEAR' AS INTERVAL DAY)"
  end

  def test_precision_scale_and_numeric_conversions
    assert_equal [["INTERVAL '1-6' YEAR TO MONTH", "INTERVAL '-2' YEAR", "INTERVAL '1 12:00:00' DAY TO SECOND", "INTERVAL '2' SECOND"]], strings("SELECT CAST(1.5 AS INTERVAL YEAR TO MONTH),CAST(-1.5 AS INTERVAL YEAR),CAST(1.5 AS INTERVAL DAY TO SECOND),CAST('1.999999999' AS INTERVAL SECOND)")
    assert_equal [[2, BigDecimal('1.5')]], rows("SELECT CAST(INTERVAL '1-6' YEAR TO MONTH AS INT),CAST(INTERVAL '1-6' YEAR TO MONTH AS NUMERIC(10,4))")
    assert_sql_error 22001, "SELECT CAST(INTERVAL '99.999999999' SECOND AS INTERVAL SECOND)"
    assert_sql_error 22007, "SELECT INTERVAL '100' DAY(2)"
    assert_sql_error 90150, "CREATE TABLE bad(i INTERVAL DAY(19))"
    assert_sql_error 90151, "CREATE TABLE bad(i INTERVAL SECOND(2,10))"
  end

  def test_comparison_keys_and_sets_promote_qualifiers_within_one_family
    assert_equal [[true, true, true]], rows("SELECT INTERVAL '1' YEAR=INTERVAL '12' MONTH,INTERVAL '1' DAY=INTERVAL '24' HOUR,INTERVAL '1' DAY='1'")
    assert_sql_error 90110, "SELECT INTERVAL '1' YEAR=INTERVAL '1' DAY"
    assert_sql_error 90110, "SELECT INTERVAL '1' DAY=1"
    assert_equal [["INTERVAL '1-0' YEAR TO MONTH"]], strings("SELECT INTERVAL '1' YEAR UNION SELECT INTERVAL '12' MONTH")
    execute("CREATE TABLE t(i INTERVAL DAY TO SECOND PRIMARY KEY)")
    execute("INSERT INTO t VALUES(INTERVAL '24' HOUR)")
    assert_sql_error 23505, "INSERT INTO t VALUES(INTERVAL '1' DAY)"
  end

  def test_extract_keeps_component_signs_and_epoch_uses_reference_month_factors
    assert_equal [[-1, -2, -3, -4, -123456789]], rows("SELECT EXTRACT(day FROM INTERVAL '-1 2:3:4.123456789' DAY TO SECOND),EXTRACT(hour FROM INTERVAL '-1 2:3:4.123456789' DAY TO SECOND),EXTRACT(minute FROM INTERVAL '-1 2:3:4.123456789' DAY TO SECOND),EXTRACT(second FROM INTERVAL '-1 2:3:4.123456789' DAY TO SECOND),EXTRACT(nanosecond FROM INTERVAL '-1 2:3:4.123456789' DAY TO SECOND)")
    assert_equal [[BigDecimal('31557600'), BigDecimal('2592000'), BigDecimal('-0.000000001')]], rows("SELECT EXTRACT(epoch FROM INTERVAL '1' YEAR),EXTRACT(epoch FROM INTERVAL '1' MONTH),EXTRACT(epoch FROM INTERVAL '-0.000000001' SECOND)")
  end

  def test_interval_arithmetic_scaling_and_aggregates
    assert_equal [["INTERVAL '1 01' DAY TO HOUR", "INTERVAL '0' YEAR", "INTERVAL '-0.000000001' SECOND"]], strings("SELECT INTERVAL '1' DAY+INTERVAL '1' HOUR,INTERVAL '1' YEAR/2,INTERVAL '-0.000000003' SECOND*0.5")
    assert_sql_error 50000, "SELECT INTERVAL '1' SECOND/3"
    assert_sql_error 50000, "SELECT INTERVAL '1' SECOND/0"
    assert_sql_error 22012, "SELECT INTERVAL '1' SECOND/INTERVAL '0' SECOND"
    assert_sql_error 22018, "SELECT INTERVAL '1' DAY*CAST(1E999 AS DOUBLE)"
    assert_equal [["INTERVAL '3' DAY", "INTERVAL '1 12:00:00' DAY TO SECOND"]], strings("SELECT SUM(i),AVG(i) FROM (VALUES INTERVAL '1' DAY,INTERVAL '2' DAY) t(i)")
  end

  def test_datetime_arithmetic_with_intervals_and_default_differences
    assert_equal [["2000-01-11", "2000-02-29 12:00:00", "09:30:00"]], strings("SELECT DATE '2000-01-10'+INTERVAL '30' HOUR,TIMESTAMP '2000-01-31 12:00:00'+INTERVAL '1' MONTH,TIME '10:00:00'-INTERVAL '30' MINUTE")
    assert_equal [["INTERVAL '15' DAY", "INTERVAL '-0:29:44.876543211' HOUR TO SECOND", "INTERVAL '2 10:30:00.5' DAY TO SECOND"]], strings("SELECT DATE '2010-01-15'-DATE '2009-12-31',TIME '10:30:15.123456789'-TIME '11:00:00',TIMESTAMP '2010-01-15 12:00:00.5'-TIMESTAMP '2010-01-13 01:30:00'")
    assert_sql_error 22003, "SELECT TIME '23:00:00'+INTERVAL '2' HOUR"
  end

  def test_postfix_casts_and_explicit_difference_qualifiers
    assert_equal [["INTERVAL '24' HOUR", "INTERVAL '2' DAY", "INTERVAL '1' YEAR", "INTERVAL '25' HOUR"]], strings("SELECT INTERVAL '1' DAY HOUR,'2' DAY,(DATE '2001-02-01'-DATE '2000-01-01') YEAR,(TIMESTAMP '2000-01-02 01:00:00'-TIMESTAMP '2000-01-01 00:00:00') HOUR(3)")
    assert_sql_error 42001, "SELECT (10-2) SECOND"
    assert_sql_error 42001, "SELECT (INTERVAL '10' HOUR-INTERVAL '1' HOUR) HOUR"
    assert_sql_error 22003, "SELECT SUM(i) FROM (VALUES INTERVAL '999999999999999999' YEAR,INTERVAL '1' YEAR,INTERVAL '-1' YEAR) t(i)"
    result = execute("SELECT (DATE '2001-02-01'-DATE '2000-01-01') YEAR")
    assert_equal "INTERVAL DAY", result.types.first.name
    assert_equal "YEAR", result.rows.first.first.qualifier
    assert_sql_error 50100, "SELECT (TIMESTAMP '2000-01-01 00:00:00'-TIME '12:00:00') YEAR TO MONTH"
  end

  def test_saved_defaults_rows_scales_and_interval_index_keys_reopen
    Dir.mktmpdir do |directory|
      path = File.join(directory, "intervals")
      value = H2::IntervalValue.parse("DAY TO SECOND", "-1 2:3:4.123456789")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(i INTERVAL DAY(5) TO SECOND(9) PRIMARY KEY,j INTERVAL YEAR TO MONTH DEFAULT INTERVAL '1-6' YEAR TO MONTH)")
        connection.execute("INSERT INTO t(i) VALUES(?)", value)
        connection.execute("CREATE TABLE r AS SELECT ROW(INTERVAL '1-6' YEAR TO MONTH,INTERVAL '0.000000001' SECOND) AS pair")
      end
      H2.connect(path: path) do |connection|
        result = connection.execute("TABLE t")
        assert_equal value, result.rows.first.first
        assert_equal [5, 2], result.types.map(&:precision)
        assert_equal [9, 0], result.types.map(&:scale)
        assert_equal [["INTERVAL '1-6' YEAR TO MONTH"]], connection.execute("SELECT j FROM t WHERE i=?", value).rows.map { it.map(&:to_s) }
        assert_equal [[H2::RowValue.new([H2::IntervalValue.parse("YEAR TO MONTH", "1-6"), H2::IntervalValue.parse("SECOND", "0.000000001")])]], connection.execute("TABLE r").rows
      end
    end
  end

  private

  def strings(sql)
    rows(sql).map { it.map(&:to_s) }
  end
end

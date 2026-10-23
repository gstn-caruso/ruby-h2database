# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class ZonedTemporalTest < DatabaseTest
  def text(sql, *parameters)
    rows(sql, *parameters).map { it.map { |value| value.nil? ? nil : value.to_s } }
  end

  def test_typed_literals_keep_offsets_and_compare_instants
    result = execute("SELECT TIME WITH TIME ZONE '12:34:56.123456789+03:30:15' AS t,TIMESTAMP WITH TIME ZONE '2000-01-01 00:00:00Z' AS ts")
    assert_equal ["TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"], result.types.map(&:name)
    assert_equal [[24, 9], [35, 9]], result.types.map { [it.precision, it.scale] }
    assert_equal [["12:34:56.123456789+03:30:15", "2000-01-01 00:00:00+00"]], result.rows.map { it.map(&:to_s) }
    assert_equal [[true, true, false]], rows("SELECT TIME WITH TIME ZONE '12:00:00+03'=TIME WITH TIME ZONE '09:00:00Z',TIMESTAMP WITH TIME ZONE '2000-01-01 00:00:00+03'=TIMESTAMP WITH TIME ZONE '1999-12-31 21:00:00Z',TIME WITH TIME ZONE '00:00:00+03'=TIME WITH TIME ZONE '21:00:00Z'")
    assert_sql_error 22007, "SELECT TIME WITH TIME ZONE '12:00:00+18:00:01'"
    assert_sql_error 22007, "SELECT TIME WITH TIME ZONE '12:00:00 Europe/Paris'"
    assert_sql_error 22007, "SELECT TIME WITH TIME ZONE U&'12:00:00\\D800'"
    assert_sql_error 90008, "SET TIME ZONE U&'\\D800'"
  end

  def test_session_zone_conversions_preserve_instants_and_local_components
    execute("SET TIME ZONE '+03:00'")
    assert_equal [["2000-01-02", "01:00:00", "2000-01-02 01:00:00", "12:00:00+03"]], text("SELECT CAST(TIMESTAMP WITH TIME ZONE '2000-01-01 22:00:00Z' AS DATE),CAST(TIMESTAMP WITH TIME ZONE '2000-01-01 22:00:00Z' AS TIME),CAST(TIMESTAMP WITH TIME ZONE '2000-01-01 22:00:00Z' AS TIMESTAMP),CAST(TIME '12:00:00' AS TIME WITH TIME ZONE)")
    assert_equal [["01:00:00", "2000-01-02 01:00:00"]], text("SELECT TIME '22:00:00Z',TIMESTAMP '2000-01-01 22:00:00Z'")
    assert_equal [["09:00:00"]], text("SELECT CAST(TIME WITH TIME ZONE '12:00:00+06' AS TIME)")
    assert_sql_error 22018, "SELECT CAST(TIME WITH TIME ZONE '12:00:00Z' AS DATE)"
    assert_sql_error 90110, "SELECT DATE '2000-01-01'=TIME WITH TIME ZONE '12:00:00Z'"
  end

  def test_zone_changes_recompile_prepared_literals_and_parameter_casts
    execute("SET TIME ZONE '+03'")
    statement = @connection.prepare("SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00',CAST(? AS TIMESTAMP WITH TIME ZONE)")
    execute("SET TIME ZONE '-05'")
    assert_equal [["2000-01-01 12:00:00-05", "2000-01-01 12:00:00-05"]], statement.execute("2000-01-01 12:00:00").rows.map { it.map(&:to_s) }
    result = @connection.execute_script("SET TIME ZONE '+02'; SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00'; SET TIME ZONE '-03'; SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00';")
    assert_equal ["2000-01-01 12:00:00+02", "2000-01-01 12:00:00-03"], [result[1], result[3]].map { it.rows.first.first.to_s }
  end

  def test_zone_changes_rebase_a_transaction_clock_and_are_connection_local
    other = @database.connect
    execute("SET TIME ZONE '+03'")
    execute("BEGIN")
    original = rows("SELECT CURRENT_TIMESTAMP(9)").first.first
    execute("SET TIME ZONE '-05'")
    changed = rows("SELECT CURRENT_TIMESTAMP(9)").first.first
    assert_equal original.epoch_nanos, changed.epoch_nanos
    assert_equal(-18_000, changed.offset_seconds)
    assert_equal original.at_offset(-18_000), changed
    assert_equal [[changed.date, changed.time]], rows("SELECT CURRENT_DATE,LOCALTIME(9)")
    other.execute("SET TIME ZONE '+09'")
    assert_equal 32_400, other.execute("SELECT CURRENT_TIMESTAMP(9)").rows.first.first.offset_seconds
    execute("ROLLBACK")
    assert_equal(-18_000, rows("SELECT CURRENT_TIMESTAMP(9)").first.first.offset_seconds)
  ensure
    other&.close
  end

  def test_at_time_zone_supports_strings_intervals_parameters_and_local
    execute("SET TIME ZONE '+03'")
    assert_equal [["2000-01-01 09:00:00+00", "01:30:00+05:30", "2000-01-01 15:00:00+03"]], text("SELECT TIMESTAMP '2000-01-01 12:00:00' AT TIME ZONE 'UTC',TIME WITH TIME ZONE '20:00:00Z' AT TIME ZONE INTERVAL '5:30' HOUR TO MINUTE,TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00Z' AT LOCAL")
    assert_equal [[nil]], rows("SELECT TIME '12:00:00' AT TIME ZONE NULL")
    assert_equal [["12:00:00-05"]], text("SELECT TIME WITH TIME ZONE '17:00:00Z' AT TIME ZONE ?", "-05")
    assert_sql_error 90008, "SELECT TIME '12:00:00' AT TIME ZONE 'Europe/Paris'"
    assert_sql_error 90008, "SET TIME ZONE INTERVAL '18:00:01' HOUR TO SECOND"
    assert_sql_error 90008, "SET TIME ZONE NULL"
    assert_sql_error 42001, "SELECT DATE '2000-01-01' AT LOCAL"
    assert_equal ["AT"], execute("SELECT 1 at").columns
  end

  def test_named_zones_handle_gap_overlap_and_calendar_specific_offsets
    execute("SET TIME ZONE 'Europe/Paris'")
    assert_equal [["2024-03-31 02:30:00+02", "2024-10-27 02:30:00+02"]], text("SELECT CAST(TIMESTAMP '2024-03-31 02:30:00' AS TIMESTAMP WITH TIME ZONE),CAST(TIMESTAMP '2024-10-27 02:30:00' AS TIMESTAMP WITH TIME ZONE)")
    assert_equal [["2024-07-01 12:00:00+02", "2024-01-01 12:00:00+01"]], text("SELECT TIMESTAMP WITH TIME ZONE '2024-07-01 12:00:00 Europe/Paris',TIMESTAMP WITH TIME ZONE '2024-01-01 12:00:00 Europe/Paris'")
    assert_equal [["2024-03-31 03:30:00"]], text("SELECT TIMESTAMP '2024-03-31 02:30:00 Europe/Paris'")
    assert_equal [["2024-07-01 06:00:00-04"]], text("SELECT TIMESTAMP WITH TIME ZONE '2024-07-01 12:00:00+02' AT TIME ZONE 'America/New_York'")
  end

  def test_rounding_keys_sets_and_parameters_preserve_offset_representations
    execute("CREATE TABLE zoned(ts TIMESTAMP(6) WITH TIME ZONE PRIMARY KEY,t TIME(0) WITH TIME ZONE)")
    execute("INSERT INTO zoned VALUES('2000-01-01 23:59:59.999999999+03','23:59:59.999999999-05')")
    assert_equal [["2000-01-02 00:00:00+03", "23:59:59-05"]], text("TABLE zoned")
    assert_sql_error 23505, "INSERT INTO zoned VALUES('2000-01-01 21:00:00Z',NULL)"
    assert_equal 1, rows("SELECT DISTINCT ts FROM zoned UNION SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 21:00:00Z'").length
    value = H2::TimestampTimeZoneValue.parse("2000-01-01 00:00:00+03")
    assert_equal [[value]], rows("SELECT ?", value)
  end

  def test_calendar_interval_and_numeric_arithmetic_keep_the_original_offset
    assert_equal [["2000-02-29 12:34:56+03", "2000-01-01 00:00:00+03", "2000-01-02 12:34:56+03", "13:00:00-05"]], text("SELECT DATEADD(month,1,TIMESTAMP WITH TIME ZONE '2000-01-31 12:34:56+03'),DATE_TRUNC(day,TIMESTAMP WITH TIME ZONE '2000-01-01 12:34:56+03'),TIMESTAMP WITH TIME ZONE '2000-01-01 12:34:56+03'+1,TIME WITH TIME ZONE '12:00:00-05'+INTERVAL '1' HOUR")
    assert_equal [[3, 30, 15, BigDecimal("946674000")]], rows("SELECT EXTRACT(timezone_hour FROM TIME WITH TIME ZONE '12:00:00+03:30:15'),EXTRACT(timezone_minute FROM TIME WITH TIME ZONE '12:00:00+03:30:15'),EXTRACT(timezone_second FROM TIME WITH TIME ZONE '12:00:00+03:30:15'),EXTRACT(epoch FROM TIMESTAMP WITH TIME ZONE '2000-01-01 00:00:00+03')")
    assert_equal [["INTERVAL '0 00:00:00' DAY TO SECOND"]], text("SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 00:00:00+03'-TIMESTAMP WITH TIME ZONE '1999-12-31 21:00:00Z'")
    assert_sql_error 50100, "SELECT TIME WITH TIME ZONE '12:00:00Z'-1"
    assert_sql_error 22018, "SELECT TIME '12:00:00'*TIME WITH TIME ZONE '12:00:00Z'"
    assert_sql_error 50000, "SELECT DATEADD(timezone_hour,2147483647,TIME WITH TIME ZONE '12:00:00Z')"
  end

  def test_saved_zoned_rows_indexes_and_dynamic_defaults_survive_reopen
    Dir.mktmpdir do |directory|
      path = File.join(directory, "zones")
      H2.connect(path: path) do |connection|
        connection.execute("SET TIME ZONE '+03'")
        connection.execute("CREATE TABLE z(ts TIMESTAMP(9) WITH TIME ZONE PRIMARY KEY,t TIME(9) WITH TIME ZONE DEFAULT TIME WITH TIME ZONE '12:34:56.123456789+03',local TIMESTAMP DEFAULT CAST(TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00Z' AS TIMESTAMP))")
        connection.execute("INSERT INTO z(ts) VALUES(TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00Z')")
      end
      H2.connect(path: path) do |connection|
        connection.execute("SET TIME ZONE '-05'")
        connection.execute("INSERT INTO z(ts) VALUES(TIMESTAMP WITH TIME ZONE '2000-01-02 12:00:00Z')")
        assert_equal ["2000-01-01 15:00:00", "2000-01-01 07:00:00"], connection.execute("SELECT local FROM z ORDER BY ts").rows.flatten.map(&:to_s)
        assert_equal ["12:34:56.123456789+03"] * 2, connection.execute("SELECT t FROM z ORDER BY ts").rows.flatten.map(&:to_s)
        error = assert_raises(H2::Error) { connection.execute("INSERT INTO z(ts) VALUES(TIMESTAMP WITH TIME ZONE '2000-01-01 15:00:00+03')") }
        assert_equal 23505, error.code
      end
    end
  end

  def test_date_boundaries_and_zone_settings_follow_reference_lifecycle
    execute("SET TIME ZONE 'UTC'")
    assert_equal [["06:00:00"]], text("SELECT CAST(TIMESTAMP WITH TIME ZONE '-1000000000-01-01 00:00:00+18' AS TIME(9))")
    assert_sql_error 50000, "SELECT TIMESTAMP WITH TIME ZONE '-1000000000-01-01 00:00:00+18' AT TIME ZONE '-18'"
    assert_sql_error 50000, "SELECT CAST(TIMESTAMP WITH TIME ZONE '-1000000000-01-01 00:00:00+18' AS DATE)"
    execute("CREATE TABLE zone_transaction(v INT)")
    execute("BEGIN")
    execute("INSERT INTO zone_transaction VALUES(1)")
    execute("SET TIME ZONE 'Europe/Paris'")
    generation = @connection.zone_generation
    execute("SET TIME ZONE 'Europe/Paris'")
    assert_equal generation, @connection.zone_generation
    execute("ROLLBACK")
    assert_equal [[0]], rows("SELECT COUNT(*) FROM zone_transaction")
    assert_equal generation, @connection.zone_generation
  end

  def test_grouping_distinct_and_distinct_aggregates_merge_equal_instants
    source = "(VALUES TIME WITH TIME ZONE '12:00:00+03',TIME WITH TIME ZONE '09:00:00Z',TIME WITH TIME ZONE '10:00:00Z',NULL) x(t)"
    assert_equal [[1], [1], [2]], rows("SELECT COUNT(*) FROM #{source} GROUP BY t ORDER BY COUNT(*)")
    assert_equal 3, rows("SELECT DISTINCT t FROM #{source}").length
    assert_equal [[2]], rows("SELECT COUNT(DISTINCT t) FROM #{source}")
  end

  def test_zone_setting_subqueries_preserve_the_reference_internal_error
    execute("CREATE TABLE zone_setting(v VARCHAR)")
    execute("BEGIN")
    execute("INSERT INTO zone_setting VALUES('+04:30')")
    before = @connection.zone_generation
    assert_sql_error 50000, "SET TIME ZONE (SELECT v FROM zone_setting)"
    assert_equal before, @connection.zone_generation
    execute("ROLLBACK")
    assert_equal [[0]], rows("SELECT COUNT(*) FROM zone_setting")
  end
end

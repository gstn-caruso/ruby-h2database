# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class DecfloatTest < DatabaseTest
  def test_finite_arithmetic_preserves_exponents_and_infers_operation_precision
    execute("CREATE TABLE t(a DECFLOAT(5),b DECFLOAT(10))")
    execute("INSERT INTO t VALUES(1,9999999999)")
    result = execute("SELECT a+b AS a,a-b AS s,a*b AS m,a/b AS d FROM t")
    assert_equal ['1E+10', '-9999999998', '9999999999', '1.0000000001E-10'], result.rows.first.map(&:to_s)
    assert_equal [11,11,15,11], result.types.map(&:precision)
    assert_equal ['DECFLOAT'] * 4, result.types.map(&:name)
    assert_equal ['0.5', '-0.5'], rows("SELECT CAST(1 AS DECFLOAT)/CAST(2 AS DECFLOAT),CAST(-1 AS DECFLOAT)/CAST(2 AS DECFLOAT)").first.map(&:to_s)
  end

  def test_special_arithmetic_keeps_h2_infinities_and_nan_rules
    result = rows("SELECT CAST('Infinity' AS DECFLOAT)+1,CAST('Infinity' AS DECFLOAT)+CAST('-Infinity' AS DECFLOAT),CAST('-Infinity' AS DECFLOAT)-CAST('Infinity' AS DECFLOAT),CAST('NaN' AS DECFLOAT)*0,CAST('-Infinity' AS DECFLOAT)*-2,CAST('Infinity' AS DECFLOAT)*0")
    assert_equal ['Infinity', 'NaN', '-Infinity', 'NaN', 'Infinity', 'NaN'], result.first.map(&:to_s)
    result = rows("SELECT CAST(1 AS DECFLOAT)/CAST('Infinity' AS DECFLOAT),CAST('-Infinity' AS DECFLOAT)/-2,CAST('Infinity' AS DECFLOAT)/CAST('Infinity' AS DECFLOAT)")
    assert_equal ['0', 'Infinity', 'NaN'], result.first.map(&:to_s)
  end

  def test_division_modulus_and_nulls_follow_sql_errors_and_signs
    assert_equal ['0.167', '-1', '1'], rows("SELECT CAST(1 AS DECFLOAT(2))/CAST(6 AS DECFLOAT(2)),MOD(CAST(-5 AS DECFLOAT),2),CAST(5 AS DECFLOAT)%-2").first.map(&:to_s)
    assert_equal [[nil, nil]], rows("SELECT CAST(NULL AS DECFLOAT)/0,CAST(1 AS DECFLOAT)+NULL")
    assert_sql_error 22012, "SELECT CAST('NaN' AS DECFLOAT)/0"
    assert_sql_error 22012, "SELECT MOD(CAST('Infinity' AS DECFLOAT),0)"
  end

  def test_abs_sign_and_aggregates_keep_decimal_values_and_special_errors
    execute("CREATE TABLE t(v DECFLOAT(5))")
    execute("INSERT INTO t VALUES(1.25),(2.5),(NULL),(1.25)")
    result = execute("SELECT SUM(v),AVG(v),SUM(DISTINCT v),AVG(v) FILTER(WHERE v>1.25) FROM t")
    assert_equal ['5', '1.66666666666667', '3.75', '2.5'], result.rows.first.map(&:to_s)
    assert_equal [15,15,15,15], result.types.map(&:precision)
    assert_equal ['Infinity', '0', '-1'], rows("SELECT ABS(CAST('-Infinity' AS DECFLOAT)),SIGN(CAST('NaN' AS DECFLOAT)),SIGN(CAST('-Infinity' AS DECFLOAT))").first.map(&:to_s)
    execute("INSERT INTO t VALUES('Infinity')")
    assert_equal 'Infinity', rows("SELECT SUM(v) FROM t").first.first.to_s
    assert_sql_error 22018, "SELECT AVG(v) FROM t"
  end

  def test_scientific_literals_and_mixed_numeric_types_infer_decfloat
    assert_equal ['DECFLOAT', 3, '1.23E+100'], [execute("SELECT 1.2300E100").types.first.name, execute("SELECT 1.2300E100").types.first.precision, rows("SELECT 1.2300E100").first.first.to_s]
    assert_equal [[true, true, true]], rows("SELECT (CAST(1 AS REAL)+CAST(1 AS BIGINT)) IS OF(DECFLOAT),(CAST(1 AS DOUBLE)+1.00) IS OF(DECFLOAT),(CAST(1 AS REAL)+1) IS OF(DOUBLE)")
    assert_equal '[1.23E100]', rows("SELECT JSON_ARRAY(SELECT v FROM (VALUES 1.2300E100) t(v))").first.first.to_s
  end

  def test_explicit_casts_keep_their_declared_precision
    result = execute("SELECT CAST('1e100' AS DECFLOAT(12)),CAST(? AS DECFLOAT(12))", '1e100')
    assert_equal [12,12], result.types.map(&:precision)
    assert_equal ['1E+100', '1E+100'], result.rows.first.map(&:to_s)
    result = execute("SELECT MOD(CAST(1.2 AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2))),MOD(CAST(? AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2)))", '1.2')
    assert_equal [[2,1],[10,2]], result.types.map { [it.precision,it.scale] }
    assert_equal [BigDecimal('1.2'),BigDecimal('1.2')], result.rows.first
  end

  def test_arithmetic_defaults_keep_literal_and_cast_precision_after_reopen
    Dir.mktmpdir("h2-decfloat") do |directory|
      path = File.join(directory, "db")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(a DECFLOAT(5),b DECFLOAT(3))")
        connection.execute("INSERT INTO source VALUES(1,6)")
        connection.execute("CREATE TABLE saved(v DECFLOAT(20) DEFAULT (SELECT a/(b+1E0) FROM source),p DECFLOAT(20) DEFAULT (SELECT a/(b+CAST(1 AS DECFLOAT(8))) FROM source))")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
      end
      H2.connect(path: path) do |connection|
        connection.execute("UPDATE source SET b=8")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
        assert_equal [['0.111111', '0.1111111111'], ['0.142857', '0.1428571429']], connection.execute("TABLE saved ORDER BY v").rows.map { it.map(&:to_s) }
      end
    end
  end

  def test_unicode_decimal_digits_and_float_specials_convert_without_losing_float_width
    assert_equal ['12.34', '1.2E+4'], rows("SELECT CAST('１２.٣٤' AS DECFLOAT),CAST('١٢e٣' AS DECFLOAT)").first.map(&:to_s)
    assert_equal [[true,0]], rows("SELECT CAST('NaN' AS DOUBLE)=CAST('NaN' AS DECFLOAT),SIGN(CAST('NaN' AS DOUBLE))")
    assert_sql_error 50100, "SELECT SIGN(TRUE) WHERE FALSE"
    value = rows("SELECT CAST(0.1E0 AS REAL)").first.first
    assert_equal [0.1].pack('f').unpack1('f'), value
    assert_equal '0000000000000000', rows("SELECT CAST(-1E-999 AS REAL)").first.first.then { [it].pack('G').unpack1('H*') }
  end

  def test_arithmetic_rejects_excess_precision_and_scale_overflow
    assert_sql_error 42001, "SELECT 1E-2147483648"
    assert_sql_error 42001, "SELECT 1E2147483649"
    assert_sql_error 22001, "SELECT 1E100000+1"
    assert_sql_error 50000, "SELECT CAST('1e-2147483647' AS DECFLOAT)*CAST('0.1' AS DECFLOAT)"
    assert_sql_error 50000, "SELECT CAST('1e2147483647' AS DECFLOAT)*CAST('100' AS DECFLOAT)"
  end
end

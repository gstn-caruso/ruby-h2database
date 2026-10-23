# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class NumericRoundingTest < DatabaseTest
  def test_round_floor_ceiling_and_trunc_use_their_decimal_rounding_rules
    result = rows("SELECT ROUND(-1.5),ROUND(10.05,1),FLOOR(-1.1),CEILING(-1.1),TRUNCATE(-1.99,1),ROUND(0.285,2)")
    assert_equal [BigDecimal('-2'),BigDecimal('10.1'),BigDecimal('-2'),BigDecimal('-1'),BigDecimal('-1.9'),BigDecimal('0.29')], result.first
    assert_equal ['1E+8', '9.99', 'NaN', 'Infinity'], rows("SELECT ROUND(99999999.99E0),TRUNC(9.999E0,2),FLOOR(CAST('NaN' AS DOUBLE)),CEIL(CAST('Infinity' AS REAL))").first.map(&:to_s)
    assert_sql_error 22018, "SELECT ROUND(CAST('Infinity' AS DECFLOAT))"
  end

  def test_runtime_numeric_metadata_distinguishes_known_and_dynamic_scales
    execute("CREATE TABLE t(n NUMERIC(10,2),s INT)")
    execute("INSERT INTO t VALUES(99999999.99,1)")
    result = execute("SELECT ROUND(n,-1),ROUND(n,1),ROUND(n,2),ROUND(n,s),TRUNC(n,-1) FROM t")
    assert_equal [[9,0],[10,1],[10,2],[11,2],[8,0]], result.types.map { [it.precision,it.scale] }
    assert_equal ['100000000','100000000.0','99999999.99','100000000.00','99999990'], result.rows.first.each_with_index.map { |v,i| H2::ArrayType.decimal_text(v,result.types[i].scale) }
  end

  def test_integer_simplification_and_negative_scales_keep_bounds_and_labels
    execute("CREATE TABLE t(i INT,n NUMERIC(4,2))")
    execute("INSERT INTO t VALUES(11,1.25)")
    assert_equal ['I','N'], execute("SELECT ROUND(i,2),ROUND(n,3) FROM t").columns
    assert_equal [[20,0]], rows("SELECT ROUND(15,-1),ROUND(2147483647,-10)")
    assert_sql_error 22003, "SELECT ROUND(2147483647,-7)"
    assert_sql_error 90008, "SELECT ROUND(NULL,100001) WHERE FALSE"
    assert_sql_error 42001, "SELECT FLOOR(1,2)"
  end

  def test_null_scales_and_runtime_nulls_keep_preparation_and_evaluation_rules
    assert_equal [[nil,nil]], rows("SELECT ROUND(NULL),TRUNC(1.25,NULL)")
    assert_sql_error 22018, "SELECT ROUND(NULL,'bad') WHERE FALSE"
    assert_equal [[nil,nil]], rows("SELECT ROUND(CAST(? AS NUMERIC(5,2)),?),TRUNC(CAST(? AS DECFLOAT(5)),?)", nil, 0, '1.25', nil)
  end

  def test_real_and_double_rounding_preserve_width_and_special_cases
    result = execute("SELECT ROUND(CAST(0.285 AS REAL),2),ROUND(CAST(0.285 AS DOUBLE),2)")
    assert_equal ['REAL','DOUBLE'], result.types.map(&:name)
    assert_equal [0.29].pack('f').unpack1('f'), result.rows.first.first
    assert_equal 0.29, result.rows.first.last
    assert_sql_error 22018, "SELECT ROUND(CAST('NaN' AS DOUBLE),0)"
    assert_equal [[-1,-2,0]], rows("SELECT CAST(CAST(-1.5 AS DOUBLE) AS INT),CAST(-1.5 AS INT),CAST(CAST('NaN' AS DOUBLE) AS INT)")
    assert_predicate rows("SELECT ROUNDMAGIC(?)",Float::NAN).first.first, :nan?
  end

  def test_trunc_temporal_values_normalizes_to_midnight_and_rejects_extra_scale
    assert_equal ['2011-03-05 00:00:00','2011-03-05 00:00:00','2011-03-05 00:00:00+07'], rows("SELECT TRUNC(DATE '2011-03-05'),TRUNCATE('2011-03-05 02:03:04'),TRUNC(TIMESTAMP WITH TIME ZONE '2011-03-05 02:03:04+07')").first.map(&:to_s)
    assert_sql_error 7001, "SELECT TRUNC(CURRENT_TIMESTAMP,1)"
    assert_sql_error 22007, "SELECT TRUNC('bad')"
    assert_equal ['2000-01-02 00:00:00','2000-01-01 00:00:00'], rows("SELECT TRUNC('2000-01-01 23:59:59.999'),TRUNC(TIMESTAMP '2000-01-01 23:59:59.999')").first.map(&:to_s)
  end

  def test_roundmagic_uses_h2s_decimal_artifact_correction
    result = rows("SELECT ROUNDMAGIC(CAST(3.11 AS DOUBLE)-3.1),ROUNDMAGIC(3.11-3.1-0.01),ROUNDMAGIC(2000000000000)")
    assert_equal [[0.01,0.0,2.0e12]], result
  end

  def test_dynamic_rounding_defaults_keep_metadata_after_reopen
    Dir.mktmpdir('h2-rounding') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(n NUMERIC(8,3),s INT)")
        connection.execute("INSERT INTO source VALUES(1.255,2)")
        connection.execute("CREATE TABLE saved(n NUMERIC(9,3) DEFAULT (SELECT ROUND(n,s) FROM source),d DECFLOAT(8) DEFAULT TRUNC(1.255E0,2),r BOOLEAN DEFAULT (SELECT FLOOR(CAST(1.5 AS REAL)) FROM source) IS OF(REAL),i BOOLEAN DEFAULT (SELECT ROUND(CAST(15 AS TINYINT),-1) FROM source) IS OF(TINYINT))")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
      end
      H2.connect(path: path) do |connection|
        connection.execute("UPDATE source SET n=-1.255,s=1")
        connection.execute("INSERT INTO saved DEFAULT VALUES")
        assert_equal [['-1.300','1.25',true,true],['1.260','1.25',true,true]], connection.execute("TABLE saved ORDER BY n").rows.map { |n,d,r,i| [H2::ArrayType.decimal_text(n,3),d.to_s,r,i] }
      end
    end
  end
end

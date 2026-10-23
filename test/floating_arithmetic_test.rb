# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class FloatingArithmeticTest < DatabaseTest
  def test_real_results_round_before_the_next_expression
    result = execute("SELECT CAST(CAST(0.1 AS REAL)+CAST(0.2 AS REAL) AS DOUBLE),CAST((CAST(0.1 AS REAL)+CAST(0.2 AS REAL))*CAST(10 AS REAL) AS DOUBLE)")
    assert_equal [[0.30000001192092896,3.0]], result.rows
    assert_equal [53,53], result.types.map(&:precision)
  end

  def test_real_intermediate_overflow_underflow_and_zero_sign
    result = rows("SELECT CAST(CAST('3.4028235e38' AS REAL)*CAST(2 AS REAL) AS DOUBLE),CAST(CAST('1.4e-45' AS REAL)/CAST(2 AS REAL) AS DOUBLE),-CAST(0 AS REAL)").first
    assert_equal [Float::INFINITY,0.0,0.0], result
    assert_equal '00000000', [result.last].pack('g').unpack1('H*')
  end

  def test_physical_result_types_discard_float_declaration_precision
    result = execute("SELECT CAST(0.1 AS FLOAT(7))+CAST(0.2 AS FLOAT(7)),CAST(1 AS REAL)+CAST(2 AS SMALLINT),CAST(1 AS REAL)+2,CAST(1 AS DOUBLE)*CAST(2 AS DOUBLE)")
    assert_equal %w[REAL REAL DOUBLE DOUBLE], result.types.map(&:name)
    assert_equal [24,24,53,53], result.types.map(&:precision)
    assert_equal ['0.3','3.0','3.0','2.0'], result.columns
  end

  def test_floating_modulus_converts_to_the_divisor_type
    result = execute("SELECT MOD(CAST(-5.5 AS REAL),CAST(2 AS SMALLINT)),CAST(-5.5 AS DOUBLE)%CAST(2 AS REAL)")
    assert_equal %w[SMALLINT REAL], result.types.map(&:name)
    assert_equal [[-1,-1.5]], result.rows
    assert_sql_error 22012, "SELECT CAST('NaN' AS REAL)/CAST(0 AS REAL)"
    assert rows("SELECT MOD(CAST('Infinity' AS DOUBLE),CAST(2 AS DOUBLE))").first.first.nan?
    assert_equal [[0.1,-0.2]], rows("SELECT CAST(0.1 AS DOUBLE)%CAST(-1.5 AS DOUBLE),CAST(-0.2 AS DOUBLE)%CAST('3.4028235e38' AS DOUBLE)")
    assert rows("SELECT CAST('Infinity' AS REAL)%CAST('-Infinity' AS REAL)").first.first.nan?
  end

  def test_nan_has_total_order_for_predicates_grouping_and_aggregates
    execute("CREATE TABLE t(v REAL)")
    execute("INSERT INTO t VALUES(CAST('NaN' AS REAL)),(CAST('Infinity' AS REAL)),(1),(NULL),(CAST('NaN' AS REAL)*1)")
    assert_equal [[true,true,true]], rows("SELECT CAST('NaN' AS REAL)=CAST('NaN' AS REAL),CAST('NaN' AS DOUBLE)>CAST('Infinity' AS DOUBLE),CAST('NaN' AS REAL) IS NOT DISTINCT FROM CAST('NaN' AS REAL)")
    assert_equal [[true,true,true]], rows("SELECT CAST(0.285 AS REAL)='0.285',CAST('NaN' AS REAL)='NaN',CAST(0.285 AS REAL)=CAST(0.285 AS NUMERIC(8,3))")
    assert_equal [nil,1.0,Float::INFINITY], rows('SELECT DISTINCT v FROM t ORDER BY v').first(3).flatten
    result = rows('SELECT MIN(v),MAX(v),COUNT(DISTINCT v) FROM t').first
    assert_equal 1.0, result[0]
    assert result[1].nan?
    assert_equal 3, result[2]
    assert_equal [[1],[1],[2]], rows('SELECT COUNT(*) FROM t WHERE v IS NOT NULL GROUP BY v ORDER BY v')
  end

  def test_floating_operand_conversion_order_and_runtime_nulls
    statement = @connection.prepare('SELECT CAST(? AS REAL)+CAST(? AS VARCHAR) AS v')
    assert_equal [[1.5]], statement.execute('1','0.5f').rows
    assert_equal [[nil]], statement.execute(nil,'0').rows
    error = assert_raises(H2::Error) { statement.execute(nil,'bad') }
    assert_equal 22018, error.code
    assert_sql_error 22018, "SELECT CAST('bad' AS VARCHAR)+(CAST(? AS REAL)/CAST(? AS REAL))", 1,0
    assert_sql_error 50004, 'SELECT MOD(?,?)',1,2
  end

  def test_real_aggregates_use_double_addition_in_reference_order
    execute('CREATE TABLE t(v REAL)')
    execute("INSERT INTO t VALUES('1e30'),('-1e30'),(1)")
    result = execute('SELECT SUM(v),AVG(v),SUM(DISTINCT v),AVG(DISTINCT v) FROM t')
    assert_equal %w[DOUBLE DOUBLE DOUBLE DOUBLE], result.types.map(&:name)
    assert_equal [53,53,53,53], result.types.map(&:precision)
    assert_equal [[1.0,1.0/3,0.0,0.0]], result.rows
  end

  def test_dynamic_arithmetic_defaults_keep_rounding_on_reopen
    Dir.mktmpdir('h2-floating') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE source(a REAL,b REAL)')
        connection.execute('INSERT INTO source VALUES(0.1,0.2)')
        connection.execute('CREATE TABLE saved(v DOUBLE DEFAULT (SELECT CAST(a+b AS DOUBLE) FROM source),n REAL DEFAULT -CAST(0 AS REAL))')
        connection.execute('INSERT INTO saved DEFAULT VALUES')
      end
      H2.connect(path: path) do |connection|
        connection.execute('UPDATE source SET a=0.3,b=0.4')
        connection.execute('INSERT INTO saved DEFAULT VALUES')
        assert_equal [[0.30000001192092896,0.0],[0.7000000476837158,0.0]], connection.execute('TABLE saved ORDER BY v').rows
      end
    end
  end
end

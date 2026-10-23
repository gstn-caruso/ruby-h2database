# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class BitFunctionsTest < DatabaseTest
  def test_integer_boolean_operations_preserve_signed_widths
    result = execute('SELECT BITAND(CAST(-59 AS TINYINT),CAST(99 AS TINYINT)),BITNAND(CAST(-59 AS TINYINT),CAST(99 AS SMALLINT)),BITOR(CAST(-59 AS TINYINT),CAST(99 AS TINYINT)),BITXOR(CAST(-59 AS TINYINT),CAST(99 AS TINYINT)),BITNOT(CAST(-59 AS TINYINT))')
    assert_equal [[65,-66,-25,-90,58]], result.rows
    assert_equal %w[TINYINT SMALLINT TINYINT TINYINT TINYINT], result.types.map(&:name)
    assert_equal [8,16,8,8,8], result.types.map(&:precision)
  end

  def test_binary_operations_align_left_and_respect_fixed_binary_precision
    result = execute("SELECT BITAND(X'c501',X'63'),BITOR(X'c501',X'63'),BITXOR(X'c501',X'63'),BITNOT(X'c501'),BITAND(CAST(X'63' AS BINARY),X'c501')")
    assert_equal %w[4100 e701 a601 3afe 41], result.rows.first.map { it.unpack1('H*') }
    assert_equal %w[VARBINARY VARBINARY VARBINARY VARBINARY BINARY], result.types.map(&:name)
    assert_equal [2,2,2,2,1], result.types.map(&:precision)
  end

  def test_shifts_and_rotations_keep_width_sign_and_large_offsets
    assert_equal [[-64,64,-128,-1,0,0,-1]], rows('SELECT RSHIFT(CAST(-128 AS TINYINT),1),URSHIFT(CAST(-128 AS TINYINT),1),LSHIFT(CAST(1 AS TINYINT),7),LSHIFT(CAST(-1 AS BIGINT),-9223372036854775808),RSHIFT(CAST(-1 AS BIGINT),-9223372036854775808),URSHIFT(CAST(-1 AS BIGINT),-9223372036854775808),ROTATELEFT(CAST(-1 AS SMALLINT),111)')
    assert_equal %w[01579a12 4055e684 579a1301 38a0], rows("SELECT LSHIFT(X'80abcd09',1),RSHIFT(X'80abcd09',1),ROTATELEFT(X'80abcd09',9),ROTATERIGHT(X'c501',3)").first.map { it.unpack1('H*') }
  end

  def test_bit_access_and_count_follow_integer_and_binary_indexing
    assert_equal [[false,true,true,8,64,3]], rows("SELECT BITGET(CAST(1 AS TINYINT),64),BITGET(CAST(1 AS BIGINT),64),BITGET(X'1001',8),BITCOUNT(CAST(-1 AS TINYINT)),BITCOUNT(CAST(-1 AS BIGINT)),BITCOUNT(X'1003')")
    assert_equal [[false]], rows('SELECT BITGET(1.5,-1)')
    assert_sql_error 90008, 'SELECT BITGET(1.5,0)'
    assert_sql_error 90008, "SELECT BITAND(1,X'01')"
    assert_sql_error 90008, "SELECT BITNOT('1') WHERE FALSE"
  end

  def test_runtime_nulls_skip_offset_conversion_and_parameters_keep_types
    statement = @connection.prepare('SELECT LSHIFT(CAST(? AS TINYINT),?) AS v')
    assert_equal [[nil]], statement.execute(nil,'bad').rows
    assert_equal [[-128]], statement.execute(1,7).rows
    assert_equal 'TINYINT', statement.execute(1,1).types.first.name
    error = assert_raises(H2::Error) { statement.execute(1,'1_0') }
    assert_equal 22018, error.code
  end

  def test_not_simplifies_boolean_operations_and_double_inversion
    execute('CREATE TABLE t(a SMALLINT,b SMALLINT)')
    execute('INSERT INTO t VALUES(3,6)')
    result = execute('SELECT BITNOT(BITNOT(a)),BITNOT(BITAND(a,b)),BITNOT(BITNAND(a,b)) FROM t')
    assert_equal ['A','BITNAND(A, B)','BITAND(A, B)'], result.columns
    assert_equal [[3,-3,2]], result.rows
  end

  def test_bit_aggregates_keep_distinct_filters_empty_groups_and_binary_width
    execute('CREATE TABLE t(i TINYINT,b VARBINARY)')
    execute("INSERT INTO t VALUES(3,X'c501'),(3,X'c501'),(1,X'63'),(NULL,NULL)")
    assert_equal [[1,3,1,2,-2,-4,-2]], rows('SELECT BIT_AND_AGG(i),BIT_OR_AGG(i),BIT_XOR_AGG(i),BIT_XOR_AGG(DISTINCT i),BIT_NAND_AGG(i),BIT_NOR_AGG(i),BIT_XNOR_AGG(i) FROM t')
    assert_equal ['4100'], rows('SELECT BIT_AND_AGG(b) FROM t').first.map { it.unpack1('H*') }
    assert_equal [[nil,nil]], rows('SELECT BIT_OR_AGG(i),BIT_XOR_AGG(b) FILTER(WHERE i<0) FROM t WHERE FALSE')
    assert_equal ['BIT_NAND_AGG(I)'], execute('SELECT BITNOT(BIT_AND_AGG(i)) FROM t').columns
    assert_equal [[1]], rows('SELECT BIT_OR_AGG(1) FILTER(WHERE i=3) FROM t')
    assert_sql_error 50004, 'SELECT BIT_AND_AGG(?)', 1
  end

  def test_query_defaults_and_captured_widths_reopen
    Dir.mktmpdir('h2-bits') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE source(v TINYINT,s BIGINT)')
        connection.execute('INSERT INTO source VALUES(1,7)')
        connection.execute("CREATE TABLE saved(v TINYINT DEFAULT (SELECT LSHIFT(v,s) FROM source),b BINARY(2) DEFAULT ROTATELEFT(X'c501',?),c BIGINT DEFAULT BITCOUNT(CAST(? AS TINYINT)))",9,-1)
        connection.execute('INSERT INTO saved DEFAULT VALUES')
      end
      H2.connect(path: path) do |connection|
        connection.execute('UPDATE source SET s=8')
        connection.execute('INSERT INTO saved DEFAULT VALUES')
        assert_equal [[-128,'038a',8],[0,'038a',8]], connection.execute('TABLE saved ORDER BY v').rows.map { |v,b,c| [v,b.unpack1('H*'),c] }
      end
    end
  end

  def test_fixed_binary_operands_keep_their_type_inside_saved_expressions
    Dir.mktmpdir('h2-bit-binary') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE source(b VARBINARY(2))')
        connection.execute("INSERT INTO source VALUES(X'c501')")
        connection.execute("CREATE TABLE saved(p VARBINARY(2) DEFAULT BITAND(BITNOT(CAST(X'00' AS BINARY)),(SELECT b FROM source)))")
        connection.execute('INSERT INTO saved DEFAULT VALUES')
      end
      H2.connect(path: path) do |connection|
        connection.execute('INSERT INTO saved DEFAULT VALUES')
        assert_equal %w[c5 c5], connection.execute('TABLE saved').rows.map { it.first.unpack1('H*') }
      end
    end
  end
end

# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

class NumericConversionTest < DatabaseTest
  def test_number_and_float_declarations_keep_physical_types_and_precision
    execute("CREATE TABLE t(n NUMBER,a NUMBER(8,2),r FLOAT(7),d FLOAT(25),f FLOAT)")
    result = execute("TABLE t")
    assert_equal ['DECFLOAT','NUMERIC','REAL','DOUBLE','DOUBLE'], result.types.map(&:name)
    assert_equal [40,8,24,53,53], result.types.map(&:precision)
    assert_sql_error 90150, "CREATE TABLE invalid_float(v FLOAT(54))"
    assert_sql_error 90150, "CREATE TABLE invalid_numeric(v NUMERIC(100001))"
    assert_sql_error 90151, "CREATE TABLE invalid_scale(v NUMERIC(2,-1))"
  end

  def test_numeric_declaration_names_and_explicit_precision_survive_cast_labels
    result = execute("SELECT CAST('1.2' AS DEC(8,2)),CAST(NULL AS FLOAT(7)),CAST(NULL AS NUMERIC(100000))")
    assert_equal ['CAST(1.20 AS DECIMAL(8, 2))','CAST(NULL AS FLOAT(7))','CAST(NULL AS NUMERIC(100000))'], result.columns
    assert_equal '1.20', H2::ArrayType.decimal_text(result.rows.first.first,2)
    assert_equal ['DECIMAL','REAL','NUMERIC'], result.types.map(&:type_name)
    assert_equal 'NUMERIC', execute("SELECT COALESCE(NULL,CAST(1.2 AS DECIMAL(8,2)))").types.first.type_name
    assert_equal "'abc'", H2::CharacterString.sql('abc'.encode(Encoding::UTF_16BE))
  end

  def test_character_integer_conversion_is_strict_and_uses_conversion_errors
    assert_equal [[123,-12,7]], rows("SELECT CAST('１２٣' AS INT),CAST(' -١٢ ' AS BIGINT),CAST('0007' AS TINYINT)")
    assert_sql_error 22018, "SELECT CAST('1_0' AS INT)"
    assert_sql_error 22018, "SELECT CAST('2147483648' AS INT)"
    assert_sql_error 22018, "SELECT CAST('128' AS TINYINT)"
    assert_sql_error 22003, "SELECT CAST(128 AS TINYINT)"
  end

  def test_decimal_and_floating_text_follow_java_numeric_syntax
    assert_equal [[BigDecimal('12.34'),3.0,0.5]], rows("SELECT CAST('１２.٣٤' AS NUMERIC(6,2)),CAST('0x1.8p1' AS DOUBLE),CAST('0.5f' AS REAL)")
    assert_sql_error 22018, "SELECT CAST('1_0' AS NUMERIC)"
    assert_sql_error 22018, "SELECT CAST('1_0' AS DOUBLE)"
    assert_sql_error 22018, "SELECT CAST('0x10' AS DOUBLE)"
    assert_sql_error 22018, "SELECT CAST('0.5f' AS NUMERIC)"
  end

  def test_real_rounding_uses_the_original_exact_value
    expected = ['3f800001','00000001','7f800000']
    values = rows("SELECT CAST('1.0000000596046448' AS REAL),CAST('7.006492321624086e-46' AS REAL),CAST('3.4028235677973367e38' AS REAL)").first
    assert_equal expected, values.map { [it].pack('g').unpack1('H*') }
    assert_equal '1.4E-45', H2::JsonValue.float_text(values[1], real: true)
    result = rows("SELECT CAST(CAST('1.0000000596046448' AS DECFLOAT) AS REAL),CAST(CAST('1.0000000596046448' AS DOUBLE) AS REAL)").first
    assert_equal ['3f800001','3f800000'], result.map { [it].pack('g').unpack1('H*') }
  end

  def test_boolean_specials_and_numeric_character_conversions_keep_semantics
    assert_equal [[false,false,true]], rows("SELECT CAST(CAST('NaN' AS DOUBLE) AS BOOLEAN),CAST(CAST('NaN' AS DECFLOAT) AS BOOLEAN),CAST(CAST('Infinity' AS DOUBLE) AS BOOLEAN)")
    assert_equal [['1.20','0.285']], rows("SELECT CAST(CAST(1.2 AS NUMERIC(8,2)) AS VARCHAR),CAST(CAST(0.285 AS REAL) AS VARCHAR)")
    assert_sql_error 22018, "SELECT CAST('1_0' AS BOOLEAN)"
    assert_sql_error 22003, "SELECT CAST(CAST('9223372036854775807.1' AS NUMERIC(20,1)) AS BIGINT)"
  end

  def test_alias_declarations_and_conversion_defaults_reopen
    Dir.mktmpdir('h2-numeric-types') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(n NUMBER DEFAULT '1e100',d DECIMAL(8,2) DEFAULT '1.20',r FLOAT(7) DEFAULT '1.0000000596046448',f FLOAT(25) DEFAULT '0x1.8p1')")
        connection.execute("INSERT INTO t DEFAULT VALUES")
      end
      H2.connect(path: path) do |connection|
        connection.execute("INSERT INTO t DEFAULT VALUES")
        result = connection.execute("TABLE t")
        assert_equal ['DECFLOAT','NUMERIC','REAL','DOUBLE'], result.types.map(&:name)
        assert_equal [40,8,24,53], result.types.map(&:precision)
        assert_equal ['1E+100','1.20','3f800001','3.0'], result.rows.first.then { |n,d,r,f| [n.to_s,H2::ArrayType.decimal_text(d,2),[r].pack('g').unpack1('H*'),f.to_s] }
      end
    end
  end

  def test_numeric_declaration_arguments_and_ordering_keep_preparation_order
    assert_equal ['CAST(NULL AS NUMERIC(3))','CAST(NULL AS FLOAT(10))'], execute("SELECT CAST(NULL AS NUMERIC(2.5)),CAST(NULL AS FLOAT(1e1))").columns
    assert_sql_error 90008, "SELECT CAST(NULL AS NUMERIC(-1e1))"
    assert_equal [[2],[1]], rows("SELECT 2 AS n UNION ALL SELECT 1 ORDER BY CAST('bad' AS INT)")
    assert_sql_error 90068, "SELECT 2 AS n UNION ALL SELECT 1 ORDER BY -CAST(1 AS INT)"
    assert_sql_error 22018, "SELECT CAST(DATE '2000-01-01' AS REAL)"
  end
end

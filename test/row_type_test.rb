# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class RowTypeTest < DatabaseTest
  def test_declared_names_types_and_metadata
    result = execute('SELECT CAST(ROW(1,2) AS ROW(a INT,"label" VARCHAR(4))) AS r')
    type = result.types.first
    assert_equal ['A','label'], type.names
    assert_equal ['INTEGER','VARCHAR'], type.fields.map(&:name)
    assert_equal 'ROW("A" INTEGER, "label" CHARACTER VARYING(4))', type.type_name
    assert_equal 2_147_483_647, type.precision
    assert_equal 0, type.scale
    assert_equal [1,'2'], result.rows.first.first.values
    assert_predicate type.names, :frozen?
  end

  def test_empty_values_and_invalid_declarations
    assert_equal [[],[]], rows('SELECT (),ROW()').first.map(&:values)
    assert_sql_error 42001, 'SELECT CAST(NULL AS ROW())'
    assert_sql_error 42121, 'SELECT CAST(NULL AS ROW(a INT,A INT))'
    assert_sql_error 22018, 'SELECT CAST(ROW(1,2) AS ROW(a INT))'
  end

  def test_field_references_validate_and_preserve_types
    result = execute('SELECT (CAST(ROW(1,2.50) AS ROW(a INT,b NUMERIC(6,2)))).b AS b')
    assert_equal [[BigDecimal('2.50')]], result.rows
    assert_equal [6,2], [result.types.first.precision,result.types.first.scale]
    assert_sql_error 42122, 'SELECT (ROW(1,2)).missing WHERE FALSE'
    assert_sql_error 90008, 'SELECT (1).a WHERE FALSE'
    assert_equal [[nil]], rows('SELECT (CAST(NULL AS ROW(a INT))).a')
    assert_equal [[2]], rows('SELECT (ROW(1,2)).c2')
  end

  def test_json_field_references_share_the_postfix_grammar
    assert_equal ['1','null',nil], rows(%q{SELECT (JSON '{"a":1,"b":null}')."a",(JSON '{"a":1,"b":null}')."b",(JSON '{"a":1}')."missing"}).first.map { it&.to_s }
  end

  def test_typed_bindings_preserve_names_and_decimal_display
    type = H2::RowType.new(fields: [H2::Type.new('INTEGER',32,0),H2::Type.new('NUMERIC',6,2)],names: ['ID','PRICE'])
    value = type.convert(H2::RowValue.new([1,BigDecimal('2.50')]))
    assert_equal 'ROW (1, 2.50)', value.to_s
    assert_equal [[BigDecimal('2.50')]], rows('SELECT (CAST(? AS ROW(id INT,price NUMERIC(6,2)))).price',value)
    assert_equal type, execute('SELECT ?',value).types.first
    assert_equal H2::RowValue.new([1,BigDecimal('2.50')]), value
    text_type = H2::RowType.new([H2::Type.new('VARCHAR',nil,nil),H2::Type.new('VARCHAR',nil,nil)])
    assert_equal ['1','2.50'], text_type.convert(value).values
  end

  def test_composite_values_and_metadata_preserve_utf16_units
    result = execute("SELECT CAST(ROW(U&'\\d800',ARRAY[U&'\\d800']) AS ROW(a ENUM(U&'\\d800'),b ENUM(U&'\\d800') ARRAY)) AS r")
    assert_equal [82,79,87,32,40,0xd800,44,32,91,0xd800,93,41], H2::CharacterString.sort_key(result.rows.first.first.to_s).unpack('n*')
    assert_includes H2::CharacterString.sort_key(result.types.first.type_name).unpack('n*'), 0xd800
    assert_equal [[1]], rows("SELECT (CAST(ROW(1) AS ROW(U&\"\\d800\" INT))).U&\"\\d800\"")
  end

  def test_named_fields_survive_arrays_sets_and_correlated_queries
    execute('CREATE TABLE t(id INT PRIMARY KEY,r ROW(a INT,b VARCHAR(4)))')
    execute("INSERT INTO t VALUES(1,ROW(1,'one')),(2,ROW(2,'two'))")
    assert_equal [[1,'one'],[2,'two']], rows('SELECT (r).a,(r).b FROM t ORDER BY (r).a')
    assert_equal [[2]], rows('SELECT id FROM t outer_t WHERE (r).a=(SELECT MAX((r).a) FROM t)')
    result = execute('SELECT CAST(ROW(1,2) AS ROW(a INT,b INT)) AS r UNION SELECT CAST(ROW(3,4) AS ROW(x INT,y INT)) ORDER BY r')
    assert_equal ['A','B'], result.types.first.names
    assert_equal [[2]], rows('SELECT (ARRAY[CAST(ROW(1,2) AS ROW(a INT,b INT))][1]).b')
  end

  def test_named_nested_rows_and_query_defaults_reopen
    Dir.mktmpdir('h2-row-types') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(r ROW(id INT,label VARCHAR(8)))")
        connection.execute("INSERT INTO source VALUES(ROW(1,'one'))")
        connection.execute('CREATE TABLE saved(r ROW(id INT,label VARCHAR(8)) DEFAULT (SELECT r FROM source),a ROW(x INT) ARRAY DEFAULT ARRAY[ROW(7)])')
        connection.execute('INSERT INTO saved DEFAULT VALUES')
      end
      H2.connect(path: path) do |connection|
        connection.execute("UPDATE source SET r=ROW(2,'two')")
        connection.execute('INSERT INTO saved DEFAULT VALUES')
        result = connection.execute('SELECT (r).id,(r).label,(a[1]).x FROM saved ORDER BY (r).id')
        assert_equal [[1,'one',7],[2,'two',7]], result.rows
        assert_equal ['ID','LABEL'], connection.execute('TABLE saved').types.first.names
      end
    end
  end

  def test_empty_row_columns_inferred_by_ctas_reopen
    Dir.mktmpdir('h2-empty-rows') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE t AS SELECT ROW() AS r,ARRAY[ROW()] AS a')
      end
      H2.connect(path: path) do |connection|
        result = connection.execute('TABLE t')
        assert_equal ['ROW()','ROW() ARRAY'], result.types.map(&:type_name)
        assert_equal ['ROW ()','[ROW ()]'], result.rows.first.map(&:to_s)
      end
    end
  end
end

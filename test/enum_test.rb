# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class EnumTest < DatabaseTest
  def test_labels_are_canonical_and_order_uses_ordinals
    execute("CREATE TABLE cards(s ENUM('hearts','clubs','spades'))")
    execute("INSERT INTO cards VALUES(' CLUBS '),('hearts'),(3),(NULL)")
    result = execute('TABLE cards ORDER BY s')
    assert_equal [nil,'hearts','clubs','spades'], result.rows.map { it.first&.to_s }
    assert_equal 'ENUM', result.types.first.name
    assert_equal "ENUM('hearts', 'clubs', 'spades')", result.types.first.type_name
    assert_equal 6, result.types.first.precision
    assert_equal [1,2,3], result.rows.drop(1).map { it.first.ordinal }
  end

  def test_declarations_reject_empty_and_duplicate_cleaned_labels
    assert_sql_error 22032, "CREATE TABLE t(e ENUM(' '))"
    assert_sql_error 22033, "CREATE TABLE t(e ENUM('one',' ONE '))"
    assert_sql_error 22030, "SELECT CAST('missing' AS ENUM('one','two'))"
    assert_sql_error 22030, "SELECT CAST(0 AS ENUM('one','two'))"
    assert_sql_error 22018, "SELECT CAST(CAST(1 AS DOUBLE) AS ENUM('one','two'))"
  end

  def test_casts_arithmetic_json_and_comparisons_preserve_enum_rules
    result = execute("SELECT CAST(CAST('clubs' AS ENUM('hearts','clubs')) AS INT),CAST(CAST(1 AS ENUM('a','b')) AS VARCHAR),CAST(2 AS ENUM('a','b'))+1,CAST(CAST(2 AS ENUM('a','b')) AS JSON)")
    assert_equal [2,'a',3,'"b"'], result.rows.first.map { it.is_a?(H2::JsonValue) ? it.to_s : it }
    assert_equal [[true]], rows("SELECT CAST('clubs' AS ENUM('hearts','clubs'))=' CLUBS '")
    assert_sql_error 90110, "SELECT CAST(1 AS ENUM('a','b'))=1"
    assert_sql_error 22018, "SELECT CAST(CAST(1 AS ENUM('a','b')) AS BOOLEAN)"
  end

  def test_arrays_sets_aggregates_and_unique_keys_use_the_descriptor
    execute("CREATE TABLE t(e ENUM('z','a') UNIQUE)")
    execute("INSERT INTO t VALUES('a'),('z'),(NULL)")
    assert_equal ['z','a'], rows('SELECT MIN(e),MAX(e) FROM t').first.map(&:to_s)
    assert_sql_error 23505, "INSERT INTO t VALUES(' Z ')"
    result = execute("SELECT CAST(1 AS ENUM('z','a')) AS e UNION SELECT CAST(2 AS ENUM('z','a')) ORDER BY e")
    assert_equal %w[z a], result.rows.map { it.first.to_s }
    assert_equal '[z, a]', rows("SELECT ARRAY[CAST(1 AS ENUM('z','a')),CAST(2 AS ENUM('z','a'))]").first.first.to_s
  end

  def test_zero_based_mode_and_typed_ruby_bindings
    H2.connect(zero_based_enums: true) do |connection|
      connection.execute("CREATE TABLE t(e ENUM('zero','one'))")
      connection.execute('INSERT INTO t VALUES(0),(1)')
      assert_equal [0,1], connection.execute('TABLE t ORDER BY e').rows.map { it.first.ordinal }
      assert_equal [[0,1]], connection.execute('SELECT CAST(MIN(e) AS INT),CAST(MAX(e) AS INT) FROM t').rows
    end
    type = H2::EnumType.new(['low','high'])
    value = type.value(' HIGH ')
    assert_equal [[2,'high']], rows('SELECT CAST(? AS INT),CAST(? AS VARCHAR)',value,value)
    assert_predicate value, :frozen?
  end

  def test_enum_keys_arrays_and_query_defaults_reopen
    [false,true].each do |zero_based|
      Dir.mktmpdir('h2-enum') do |directory|
        path = File.join(directory,'db')
        H2.connect(path: path,zero_based_enums: zero_based) do |connection|
          connection.execute("CREATE TABLE source(e ENUM('a','b','c') PRIMARY KEY)")
          connection.execute("INSERT INTO source VALUES('a')")
          connection.execute("CREATE TABLE saved(e ENUM('a','b','c') DEFAULT (SELECT MIN(e) FROM source),a ENUM('a','b','c') ARRAY DEFAULT ARRAY[CAST('b' AS ENUM('a','b','c'))])")
          connection.execute('INSERT INTO saved DEFAULT VALUES')
        end
        H2.connect(path: path,zero_based_enums: zero_based) do |connection|
          connection.execute("UPDATE source SET e='c'")
          connection.execute('INSERT INTO saved DEFAULT VALUES')
          result = connection.execute('TABLE saved ORDER BY e')
          assert_equal [%w[a [b]],%w[c [b]]], result.rows.map { it.map(&:to_s) }
          assert_equal [zero_based ? 0 : 1,zero_based ? 2 : 3], result.rows.map { it.first.ordinal }
        end
      end
    end
  end

  def test_unicode_labels_preserve_utf16_units_and_validation
    result = execute("SELECT CAST(U&'\\d800' AS ENUM(U&'\\d800','😀')) AS e")
    assert_equal [0xd800], H2::CharacterString.sort_key(result.rows.first.first.label).unpack('n*')
    assert_equal 2, result.types.first.precision
    assert_equal "ENUM(U&'\\d800', '😀')", result.types.first.sql
    assert_sql_error 22033, "SELECT CAST(NULL AS ENUM('ß','SS'))"
  end

  def test_ordinals_beyond_compact_integer_tags_reopen
    Dir.mktmpdir('h2-enum-tags') do |directory|
      path = File.join(directory,'db')
      labels = (1..20).map { "'label#{it}'" }.join(',')
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(e ENUM(#{labels}) PRIMARY KEY)")
        connection.execute('INSERT INTO t VALUES(1),(15),(16),(20)')
      end
      H2.connect(path: path) do |connection|
        assert_equal [1,15,16,20], connection.execute('TABLE t ORDER BY e').rows.map { it.first.ordinal }
      end
    end
  end
end

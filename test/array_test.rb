# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "h2/mvstore"

class ArrayTest < DatabaseTest
  def test_constructors_promote_components_and_keep_nested_arrays_immutable
    result = execute("SELECT ARRAY[],ARRAY[1,NULL,'3'],ARRAY[ARRAY[1,2],ARRAY[3]][2][1]")
    empty, mixed, element = result.rows.first
    assert_equal [], empty.values
    assert_equal [1, nil, 3], mixed.values
    assert_equal 3, element
    assert_equal ["NULL ARRAY", "INTEGER ARRAY", "INTEGER"], result.types.map(&:name)
    assert_equal [0, 3], result.types.first(2).map(&:precision)
    assert mixed.frozen?
    assert mixed.values.frozen?
  end

  def test_element_indexes_are_one_based_and_null_propagating
    assert_equal [[10, 30, nil, nil]], rows("SELECT ARRAY[10,20,30][1],ARRAY[10,20,30][3],ARRAY[1][NULL],NULL[1]")
    assert_sql_error 22034, "SELECT ARRAY[1][0]"
    assert_sql_error 22034, "SELECT ARRAY[1][2]"
    assert_sql_error 90008, "SELECT ROW(1,2)[1]"
    assert_sql_error 90008, "SELECT 1[1] WHERE FALSE"
  end

  def test_array_casts_truncate_after_conversion_and_assignments_enforce_cardinality
    execute("CREATE TABLE arrays(id INT PRIMARY KEY,a INT ARRAY[2],nested TIME ARRAY[2] ARRAY[1])")
    execute("INSERT INTO arrays VALUES(1,ARRAY[1.0,NULL],ARRAY[ARRAY[TIME '12:00:00']])")
    assert_equal [1, nil], rows("SELECT a FROM arrays").first.first.values
    assert_equal [["12:00:00"]], rows("SELECT nested FROM arrays").first.first.values.map { it.values.map(&:to_s) }
    assert_sql_error 22001, "INSERT INTO arrays(id,a) VALUES(2,ARRAY[1,2,3])"
    assert_equal [1], rows("SELECT CAST(ARRAY[1,2] AS INT ARRAY[1])").first.first.values
    assert_sql_error 22018, "SELECT CAST(ARRAY['1','bad'] AS INT ARRAY[1])"
    assert_sql_error 90150, "CREATE TABLE invalid(a INT ARRAY[65537])"
  end

  def test_array_comparison_retains_unknowns_and_compares_lengths_for_equality
    assert_equal [[nil, false, false, true, nil, true, nil]], rows("SELECT ARRAY[1,NULL]=ARRAY[1,NULL],ARRAY[NULL]=ARRAY[NULL,NULL],ARRAY[1,NULL,2]=ARRAY[1,NULL,1],ARRAY[1,2,NULL]>ARRAY[1,1,NULL],ARRAY[1,NULL]>ARRAY[1,NULL],ARRAY[1,NULL] IS NOT DISTINCT FROM ARRAY[1,NULL],ARRAY[1,NULL] IN(ARRAY[1,NULL])")
    assert_sql_error 90110, "SELECT ARRAY[1,2]=ROW(1,2)"
  end

  def test_concatenation_and_subquery_arrays_retain_components_and_correlations
    assert_equal [1, 2, 3], rows("SELECT ARRAY[1,2]||3").first.first.values
    assert_equal [1, 2, 3], rows("SELECT 1||ARRAY[2,3]").first.first.values
    assert_equal [[nil]], rows("SELECT ARRAY[1]||NULL")
    assert_equal [3, 2, 1], rows("SELECT ARRAY(SELECT x FROM SYSTEM_RANGE(1,3) ORDER BY x DESC)").first.first.values
    assert_equal [[1, [1]], [2, [1, 2]]], rows("SELECT n,ARRAY(SELECT x FROM SYSTEM_RANGE(1,3) WHERE x<=n) FROM (VALUES 1,2) t(n) ORDER BY n").map { |n, a| [n, a.values] }
    assert_equal [], rows("SELECT ARRAY(SELECT x FROM SYSTEM_RANGE(1,3) WHERE FALSE)").first.first.values
    assert_sql_error 90052, "SELECT ARRAY(SELECT 1,2)"
  end

  def test_array_functions_keep_null_containment_separate_from_sql_membership
    assert_equal [[3, 2, true, nil, nil]], rows("SELECT CARDINALITY(ARRAY[1,NULL,3]),ARRAY_MAX_CARDINALITY(CAST(NULL AS INT ARRAY[2])),ARRAY_CONTAINS(ARRAY[1,NULL],NULL),ARRAY_CONTAINS(1,1),CARDINALITY(NULL)")
    assert_equal [1, nil], rows("SELECT TRIM_ARRAY(ARRAY[1,NULL,3],1)").first.first.values
    assert_equal [nil, 3], rows("SELECT ARRAY_SLICE(ARRAY[1,NULL,3],2,3)").first.first.values
    assert_equal [[nil]], rows("SELECT ARRAY_SLICE(ARRAY[1,2],0,1)")
    assert_sql_error 22034, "SELECT TRIM_ARRAY(NULL,-1)"
    assert_sql_error 22034, "SELECT TRIM_ARRAY(ARRAY[1],2)"
    assert_sql_error 90008, "SELECT ARRAY_MAX_CARDINALITY(NULL)"
    assert_sql_error 90008, "SELECT TRIM_ARRAY(1,0) WHERE FALSE"
  end

  def test_ruby_array_parameters_are_reusable_and_deeply_copied
    input = [[+"a", nil], [+"b"]]
    value = rows("SELECT ?", input).first.first
    input.first.first.replace("changed")
    input.last << "c"
    assert_equal [["a", nil], ["b"]], value.values.map(&:values)
    statement = @connection.prepare("SELECT CAST(? AS INT ARRAY[2]),ARRAY_GET(CAST(? AS INT ARRAY),?)")
    assert_equal [[1, 2], 3], statement.execute([1, 2, 3], [3, 4], 1).rows.first.map { it.is_a?(H2::ArrayValue) ? it.values : it }
    assert_equal [[nil, nil]], statement.execute(nil, nil, 1).rows
    assert_sql_error 22018, "SELECT ?", [Object.new]
    cyclic = []
    cyclic << cyclic
    assert_sql_error 22018, "SELECT ?", cyclic
  end

  def test_file_arrays_keep_nested_types_keys_and_query_defaults_after_reopen
    Dir.mktmpdir("h2-arrays") do |directory|
      path = File.join(directory, "arrays")
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE source(v INT)")
        connection.execute("INSERT INTO source VALUES(1),(2)")
        connection.execute("CREATE TABLE saved(a INT ARRAY PRIMARY KEY,n TIME(9) ARRAY[3] ARRAY[2],d INT ARRAY DEFAULT ARRAY(SELECT v FROM source ORDER BY v))")
        connection.execute("INSERT INTO saved(a,n) VALUES(ARRAY[],ARRAY[ARRAY[TIME '12:34:56.123456789']]),(ARRAY[1],NULL),(ARRAY[1,2],NULL)")
      end
      H2.connect(path: path) do |connection|
        assert_equal [[], [1], [1, 2]], connection.execute("SELECT a FROM saved ORDER BY a").rows.map { it.first.values }
        assert_equal "12:34:56.123456789", connection.execute("SELECT n[1][1] FROM saved WHERE a=ARRAY[]").rows.first.first.to_s
        connection.execute("INSERT INTO source VALUES(3)")
        connection.execute("INSERT INTO saved(a) VALUES(ARRAY[2])")
        assert_equal [1, 2, 3], connection.execute("SELECT d FROM saved WHERE a=ARRAY[2]").rows.first.first.values
        error = assert_raises(H2::Error) { connection.execute("INSERT INTO saved(a) VALUES(ARRAY[1])") }
        assert_equal 23505, error.code
        error = assert_raises(H2::Error) { connection.execute("DROP TABLE source") }
        assert_equal 90107, error.code
      end
    end
  end

  def test_decimal_components_keep_their_scale_and_numeric_promotion
    value = rows("SELECT ARRAY[1,2]||ARRAY[1.00,2.25]").first.first
    assert_equal "[1.00, 2.00, 1.00, 2.25]", value.to_s
    assert_equal "NUMERIC(12, 2)", H2::SQLTypeName.format(value.element_type)
    assert_equal [[false, true]], rows("SELECT ARRAY[1]=ARRAY['bad','bad'],ARRAY[1,NULL] IS DISTINCT FROM ARRAY[NULL,'bad']")
    assert_sql_error 22018, "SELECT ARRAY[1] IS DISTINCT FROM ARRAY['bad','bad']"
    assert_equal [[true]], rows("SELECT ARRAY_CONTAINS(ARRAY[X'00',X'ff'],X'00')")
  end

  def test_equivalent_zoned_array_keys_share_one_sql_identity
    execute("CREATE TABLE zoned_arrays(a TIME(9) WITH TIME ZONE ARRAY UNIQUE)")
    execute("INSERT INTO zoned_arrays VALUES(ARRAY[TIME WITH TIME ZONE '12:00:00+03'])")
    assert_sql_error 23505, "INSERT INTO zoned_arrays VALUES(ARRAY[TIME WITH TIME ZONE '09:00:00Z'])"
    assert_equal [[1]], rows("SELECT COUNT(DISTINCT a) FROM(VALUES(ARRAY[TIME WITH TIME ZONE '12:00:00+03']),(ARRAY[TIME WITH TIME ZONE '09:00:00Z'])) t(a)")
  end

  def test_unknown_array_components_and_element_inputs_fail_during_preparation
    {"SELECT ARRAY[?]" => 50004, "SELECT ARRAY[?,NULL]" => 50004, "SELECT ?[1]" => 50004,
      "SELECT TRIM_ARRAY(?,0)" => 50004}.each do |sql, code|
      error = assert_raises(H2::Error) { @connection.prepare(sql) }
      assert_equal code, error.code
    end
    statement = @connection.prepare("SELECT ARRAY[CAST(? AS INT)]")
    assert_equal [3], statement.execute(3).rows.first.first.values
  end

  def test_raw_array_key_prefixes_keep_ascending_order_and_lookup_after_reopen
    keys = [[], [1], [1, 2], [1, 2, 3], [2]]
    encoded = keys.map { |key| H2::MVStore::Value.new(:array, key.map { H2::MVStore::Value.new(:integer, it) }) }
    Dir.mktmpdir("h2-array-keys") do |directory|
      path = File.join(directory, "arrays")
      H2::MVStore::Store.open(path) do |store|
        map = store.open_map("arrays", key_type: :value, value_type: :string)
        encoded.reverse_each { map[it] = it.to_ruby.inspect }
        assert_equal keys, map.map { |key, _value| key.to_ruby }
      end
      H2::MVStore::Store.open(path, read_only: true) do |store|
        map = store.open_map("arrays", key_type: :value, value_type: :string)
        assert_equal keys, map.map { |key, _value| key.to_ruby }
        encoded.zip(keys).each { |key, value| assert_equal value.inspect, map[key] }
      end
    end
  end
end

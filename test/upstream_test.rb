# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/upstream_script"

class UpstreamTest < DatabaseTest
  ROOT = File.expand_path("../h2/src/test/org/h2/test/scripts", __dir__)
  COMPLETE_SCRIPTS = %w[datatypes/int.sql datatypes/uuid.sql functions/string/upper.sql functions/string/lower.sql
    functions/system/coalesce.sql functions/numeric/mod.sql functions/system/nullif.sql
    functions/timeanddate/dateadd.sql functions/timeanddate/datediff.sql functions/timeanddate/last_day.sql
    functions/system/array-cat.sql functions/system/trim_array.sql functions/numeric/sign.sql functions/numeric/roundmagic.sql
    functions/numeric/bitget.sql functions/numeric/lshift.sql functions/numeric/rshift.sql functions/numeric/rotate.sql].freeze

  COMPLETE_SCRIPTS.each do |path|
    define_method("test_complete_#{path.tr('/.', '__')}") do
      script = UpstreamScript.new(File.join(ROOT, path))
      refute_empty script.cases
      script.cases.each { check_case(it) }
    end
  end

  def test_original_insert_first_six_statements
    script = UpstreamScript.new(File.join(ROOT, "dml/insert.sql"))
    script.cases.first(6).each { check_case(it) }
  end

  def test_original_values_first_three_statements
    script = UpstreamScript.new(File.join(ROOT, "queries/values.sql"))
    script.cases.first(3).each { check_case(it) }
  end

  def test_original_join_first_seven_statements
    script = UpstreamScript.new(File.join(ROOT, "queries/joins.sql"))
    script.cases.first(7).each { check_case(it) }
  end

  def test_original_range_queries_except_plans_and_parameter_block
    script = UpstreamScript.new(File.join(ROOT, "range_table.sql"))
    [3, 5, 6, 7].each { check_case(script.cases.fetch(it)) }
    script.cases[8..39].each { check_case(it) }
  end

  def test_original_table_first_seven_statements
    script = UpstreamScript.new(File.join(ROOT, "queries/table.sql"))
    script.cases.first(7).each { check_case(it) }
  end

  def test_original_binary_statements_except_metadata_and_settings
    script = UpstreamScript.new(File.join(ROOT, "datatypes/binary.sql"))
    [0, 2, *(3..9), 11, 14].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_varbinary_statements_except_metadata_tools_modes_and_settings
    script = UpstreamScript.new(File.join(ROOT, "datatypes/varbinary.sql"))
    [0, 2, *(7..20), *(28..31), 33, 36, 37].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_blob_statements_except_information_schema
    script = UpstreamScript.new(File.join(ROOT,'datatypes/blob.sql'))
    [0,2,3,*(5..12)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_clob_statements_except_information_schema
    script = UpstreamScript.new(File.join(ROOT,'datatypes/clob.sql'))
    [0,2,3,*(5..13)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_set_query_ordering_pagination_and_row_membership
    script = UpstreamScript.new(File.join(ROOT, "queries/select.sql"))
    [*(42..46), *(149..156)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_common_table_queries_except_plans_schemas_views_and_delta_tables
    script = UpstreamScript.new(File.join(ROOT, "dml/with.sql"))
    [*(0..3), *(6..10), *(12..15), *(18..28), *(39..45), *(49..51)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_date_statements_except_information_schema
    script = UpstreamScript.new(File.join(ROOT, "datatypes/date.sql"))
    [0, *(2..16)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_time_statements_except_metadata_and_alter_table
    script = UpstreamScript.new(File.join(ROOT, "datatypes/time.sql"))
    [*(0..2), *(7..33)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_timestamp_statements_except_metadata_and_alter_table
    script = UpstreamScript.new(File.join(ROOT, "datatypes/timestamp.sql"))
    [*(0..2), *(6..39)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_time_zone_statements_except_metadata_and_alter_table
    script = UpstreamScript.new(File.join(ROOT, "datatypes/time-with-time-zone.sql"))
    [*(0..2), *(7..25)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_timestamp_zone_statements_except_metadata_and_alter_table
    script = UpstreamScript.new(File.join(ROOT, "datatypes/timestamp-with-time-zone.sql"))
    [*(0..7), *(10..31)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_current_time_except_string_functions_and_plans
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/current-time.sql"))
    [*(0..4), *(7..9)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_current_timestamp_before_java_aliases_identity_and_modes
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/current_timestamp.sql"))
    script.cases.first(8).each { check_case(it) }
  end

  def test_original_date_trunc_statements_except_zones_directives_and_modes
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/date_trunc.sql"))
    ranges = [1..13, 26..45, 58..77, 90..107, 114..126, 133..146, 153..161, 165..174,
      181..195, 202..209, 216..224, 231..241, 248..256, 263..267, 271..290]
    ranges.each { |range| range.each { check_case(script.cases.fetch(it)) } }
  end

  def test_original_extract_statements_except_types_zones_and_modes
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/extract.sql"))
    [*(2..12), *(16..22), *(30..61), *(65..82)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_interval_values_casts_and_initial_arithmetic
    script = UpstreamScript.new(File.join(ROOT, "datatypes/interval.sql"))
    [0, 2, *(4..180), *(187..190), *(195..215), *(217..240), 245, 246, *(248..317)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_arrays_except_metadata_memory_tables_scripts_indexes_and_reconnect
    script = UpstreamScript.new(File.join(ROOT, "datatypes/array.sql"))
    [*(0..37), *(39..42), 56, 57, 58, *(61..68), *(71..78)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_array_contains_before_identity_columns
    script = UpstreamScript.new(File.join(ROOT, "functions/system/array-contains.sql"))
    script.cases.first(9).each { check_case(it) }
  end

  def test_original_array_slice_in_regular_mode
    script = UpstreamScript.new(File.join(ROOT, "functions/system/array-slice.sql"))
    [*(0..4), *(10..12)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_cardinality_except_json_and_array_aggregation
    script = UpstreamScript.new(File.join(ROOT, "functions/system/cardinality.sql"))
    [0, 1, 2, *(5..7), *(9..12)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_array_aggregation_except_indexes_identity_windows_and_plans
    script = UpstreamScript.new(File.join(ROOT, "functions/aggregate/array_agg.sql"))
    [0, 1, 2, 4, 5, 6, *(13..16), 37, 61, 62, *(70..77)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_unnest_except_plans
    script = UpstreamScript.new(File.join(ROOT, "functions/system/unnest.sql"))
    [*(0..5), *(8..12)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_quantified_array_comparisons_except_indexes_and_plans
    script = UpstreamScript.new(File.join(ROOT, "predicates/quantified-comparison-with-array.sql"))
    [*(0..5), 7, 9, 12, 14, 16, *(18..22)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_json_datatype_except_tooling_other_types_and_helpers
    script = UpstreamScript.new(File.join(ROOT, "datatypes/json.sql"))
    [*(0..19), 21, 22, 24, 25, 32, 33, 34, 38, 41, 42, 43, 44, *(48..53), 60, 61, 63, 66, *(69..72), *(74..79)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_decfloat_casts_mixed_types_specials_and_scientific_literals
    script = UpstreamScript.new(File.join(ROOT, "datatypes/decfloat.sql"))
    [*(10..16), *(27..40)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_floor_and_ceiling_except_information_schema
    {"floor" => [*(0..5),7],"ceil" => [*(0..6),8]}.each do |name, selection|
      script = UpstreamScript.new(File.join(ROOT,"functions/numeric/#{name}.sql"))
      selection.each { check_case(script.cases.fetch(it)) }
    end
  end

  def test_original_numeric_declarations_limits_and_assignment_rounding
    script = UpstreamScript.new(File.join(ROOT,"datatypes/numeric.sql"))
    [3,*(9..14),*(20..28),*(30..32)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_real_and_integer_comparison
    script = UpstreamScript.new(File.join(ROOT,"datatypes/real.sql"))
    (7..9).each { check_case(script.cases.fetch(it)) }
  end

  def test_original_binary_floating_special_value_matrices_with_native_table_setup
    {'real' => ['REAL',[*(11..15),18]], 'double_precision' => ['DOUBLE',[*(7..11),14]]}.each do |name,(type,selection)|
      execute("CREATE TABLE TEST(D #{type})")
      execute("INSERT INTO TEST VALUES('-Infinity'),('-1'),('0'),('1'),('1.5'),('Infinity'),('NaN')")
      script = UpstreamScript.new(File.join(ROOT,"datatypes/#{name}.sql"))
      selection.each { check_case(script.cases.fetch(it)) }
    end
  end

  def test_original_bit_logical_functions_except_explain
    %w[bitand bitor bitxor].each do |name|
      script = UpstreamScript.new(File.join(ROOT,"functions/numeric/#{name}.sql"))
      [0,1,2,3,5,*(12..15)].each { check_case(script.cases.fetch(it)) }
    end
  end

  def test_original_bit_not_except_explain
    script = UpstreamScript.new(File.join(ROOT,'functions/numeric/bitnot.sql'))
    [0,1,3,5].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_bit_count_except_explain
    script = UpstreamScript.new(File.join(ROOT,'functions/numeric/bitcount.sql'))
    [0,*(2..5)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_bit_aggregates_except_index_plans_and_windows
    {'bit_and_agg'=>[0,1,2,3,5,6,10],'bit_or_agg'=>[0,1,2,3,5,6,8],'bit_xor_agg'=>[0,1,2,4]}.each do |name,selection|
      script = UpstreamScript.new(File.join(ROOT,"functions/aggregate/#{name}.sql"))
      selection.each { check_case(script.cases.fetch(it)) }
    end
  end

  def test_original_enum_values_except_alter_domains_views_and_metadata
    script = UpstreamScript.new(File.join(ROOT,'datatypes/enum.sql'))
    [0,1,3,7,15,19,22,57,58,73,74,75,77,78,79,80].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_round_except_call_and_information_schema
    script = UpstreamScript.new(File.join(ROOT,"functions/numeric/round.sql"))
    [*(0..2),5,6,*(16..18),*(20..28)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_truncate_except_information_schema
    script = UpstreamScript.new(File.join(ROOT,"functions/numeric/truncate.sql"))
    [*(0..23),*(25..27)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_json_array_except_plans_and_string_helpers
    script = UpstreamScript.new(File.join(ROOT, "functions/json/json_array.sql"))
    [*(0..6), 10, *(15..21)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_json_object_except_plans_helpers_and_modes
    script = UpstreamScript.new(File.join(ROOT, "functions/json/json_object.sql"))
    [*(0..12), 15, 20, 21].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_row_values_declarations_and_casts
    script = UpstreamScript.new(File.join(ROOT,'datatypes/row.sql'))
    (0..35).each { check_case(script.cases.fetch(it)) }
  end

  private

  def check_case(scenario)
    expected = scenario.expected
    location = "#{scenario.path}:#{scenario.line}\n#{scenario.sql}"
    if expected.first&.start_with?("exception ")
      code_name = expected.first.delete_prefix("exception ")
      source = File.read(File.expand_path("../h2/src/main/org/h2/api/ErrorCode.java", __dir__))
      code = source.match(/public static final int #{Regexp.escape(code_name)} = (\d+);/)&.captures&.first
      refute_nil code, location
      error = assert_raises(H2::Error, location) { execute(scenario.sql) }
      assert_equal code.to_i, error.code, location
      return
    end

    result = execute(scenario.sql)
    if expected == ["ok"]
      assert_equal 0, result.update_count, location
    elsif expected.first&.start_with?("update count: ")
      assert_equal expected.first.delete_prefix("update count: ").to_i, result.update_count, location
    elsif scenario.scalar
      assert_equal 1, result.rows.length, location
      assert_equal [expected.first], result.rows.first.each_with_index.map { |value, index| text(value, result.types[index]) }, location
    else
      spans = expected.fetch(1).enum_for(:scan, /-+/).map { Regexp.last_match.begin(0)...Regexp.last_match.end(0) }
      assert_equal spans.map { expected.first[it].strip }, result.columns.map { text(it) }, location
      expected_rows = expected[2...-1].map { |line| spans.map { line[it].to_s.strip } }
      actual_rows = result.rows.map { |row| row.each_with_index.map { |value, index| text(value, result.types[index]) } }
      if expected.last.start_with?("rows (ordered):")
        assert_equal expected_rows, actual_rows, location
      else
        assert_equal expected_rows.sort, actual_rows.sort, location
      end
      assert_equal expected.last.split.last.to_i, actual_rows.length, location
    end
  end

  def text(value, type = nil)
    case value
    when nil then "null"
    when true then "TRUE"
    when false then "FALSE"
    when BigDecimal
      text = value.to_s("F")
      if type&.scale == 0 && value.frac.zero?
        value.to_i.to_s
      elsif type&.scale.to_i.positive?
        integer, fraction = text.split(".")
        "#{integer}.#{fraction.to_s.ljust(type.scale, '0')}"
      else text
      end
    when Float then H2::JsonValue.float_text(value, real: type&.name == "REAL")
    when H2::BlobValue then "X'#{value.bytes.unpack1('H*')}'"
    when H2::ClobValue then text(value.to_s,type)
    when String then H2::BinaryString.binary?(value) ? "X'#{value.unpack1('H*')}'" : value.gsub("\r\n", "\n").tr("\n", " ").gsub(/ +/, " ")
    else value.to_s
    end
  end
end

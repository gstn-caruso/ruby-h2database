# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/upstream_script"

class UpstreamTest < DatabaseTest
  ROOT = File.expand_path("../h2/src/test/org/h2/test/scripts", __dir__)
  COMPLETE_SCRIPTS = %w[datatypes/int.sql datatypes/uuid.sql functions/string/upper.sql functions/string/lower.sql
    functions/system/coalesce.sql functions/numeric/mod.sql functions/system/nullif.sql].freeze

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

  def test_original_dateadd_statements_except_zoned_values
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/dateadd.sql"))
    [*(0..9), 13, 15, *(19..28), 30, 36, *(39..42)].each { check_case(script.cases.fetch(it)) }
  end

  def test_original_datediff_statements_except_zoned_values
    script = UpstreamScript.new(File.join(ROOT, "functions/timeanddate/datediff.sql"))
    [*(0..37), *(46..59)].each { check_case(script.cases.fetch(it)) }
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
    when String then H2::BinaryString.binary?(value) ? "X'#{value.unpack1('H*')}'" : value.gsub("\r\n", "\n").tr("\n", " ").gsub(/ +/, " ")
    else value.to_s
    end
  end
end

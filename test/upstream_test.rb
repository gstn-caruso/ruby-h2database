# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/upstream_script"

class UpstreamTest < DatabaseTest
  ROOT = File.expand_path("../h2/src/test/org/h2/test/scripts", __dir__)
  COMPLETE_SCRIPTS = %w[datatypes/int.sql functions/string/upper.sql functions/string/lower.sql
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
      assert_equal [expected.first], result.rows.first.map { text(it) }, location
    else
      spans = expected.fetch(1).enum_for(:scan, /-+/).map { Regexp.last_match.begin(0)...Regexp.last_match.end(0) }
      assert_equal spans.map { expected.first[it].strip }, result.columns.map { text(it) }, location
      expected_rows = expected[2...-1].map { |line| spans.map { line[it].to_s.strip } }
      actual_rows = result.rows.map { |row| row.map { text(it) } }
      if expected.last.start_with?("rows (ordered):")
        assert_equal expected_rows, actual_rows, location
      else
        assert_equal expected_rows.sort, actual_rows.sort, location
      end
      assert_equal expected.last.split.last.to_i, actual_rows.length, location
    end
  end

  def text(value)
    case value
    when nil then "null"
    when true then "TRUE"
    when false then "FALSE"
    when BigDecimal then value.to_s("F")
    when String then value.gsub("\r\n", "\n").tr("\n", " ").gsub(/ +/, " ")
    else value.to_s
    end
  end
end

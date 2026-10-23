# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

statements = []
fields = %w[MICROSECOND MILLISECOND SECOND MINUTE HOUR DAY ISO_WEEK WEEK ISO_WEEK_YEAR WEEK_YEAR MONTH QUARTER YEAR DECADE CENTURY MILLENNIUM]
years = [-1_000_000_000, -1001, -1000, -999, -100, -99, -11, -10, -1, 0, 1, 4, 1900, 1999, 2000, 2001, 2016, 2017, 2019, 2020, 1_000_000_000]
calendar_fields = %w[MILLENNIUM CENTURY DECADE DAY_OF_YEAR DOW ISO_DAY_OF_WEEK ISO_WEEK ISO_WEEK_YEAR WEEK WEEK_YEAR EPOCH]
years.product([[1, 1], [1, 4], [2, 28], [3, 1], [12, 28], [12, 31]]).each do |year, (month, day)|
  text = "#{year.negative? ? '-' : ''}#{year.abs.to_s.rjust(4, '0')}-#{month.to_s.rjust(2, '0')}-#{day.to_s.rjust(2, '0')}"
  fields.product(["DATE '#{text}'", "TIMESTAMP '#{text} 12:34:56.123456789'"]).each do |field, value|
    statements << "SELECT DATE_TRUNC(#{field},#{value}) AS v;"
  end
  expressions = calendar_fields.map { |field| "EXTRACT(#{field} FROM DATE '#{text}') AS #{field}" }
  statements << "SELECT #{expressions.join(',')},LAST_DAY(DATE '#{text}') AS last_day;"
end
(1800...2200).each do |year|
  [[1, 1], [1, 4], [12, 29], [12, 31]].each do |month, day|
    value = "DATE '#{year}-#{month.to_s.rjust(2, '0')}-#{day.to_s.rjust(2, '0')}'"
    expressions = %w[ISO_WEEK ISO_WEEK_YEAR WEEK WEEK_YEAR].map { "EXTRACT(#{it} FROM #{value}) AS #{it}" }
    statements << "SELECT #{expressions.join(',')},DATE_TRUNC(ISO_WEEK_YEAR,#{value}) AS iso_start,DATE_TRUNC(WEEK_YEAR,#{value}) AS local_start;"
  end
end
fields.product(["00:00:00", "00:00:00.000000001", "12:34:56.123456789", "23:59:59.999999999"]).each do |field, time|
  statements << "SELECT DATE_TRUNC(#{field},TIME '#{time}') AS t,EXTRACT(EPOCH FROM TIME '#{time}') AS e;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Calendar functions: #{statements.length} generated Java comparisons passed (400-year week cycle, signed/extreme years, truncation, fields and nanosecond epoch values)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-Duser.language=en", "-Duser.country=US", "-cp", jar, File.join(__dir__, "CalendarParametersOracle.java"))
abort error unless status.success?
actual = H2.connect do |connection|
  cases = [
    ["SELECT DATE_TRUNC(year,CAST(? AS DATE)) AS v,LAST_DAY(?) AS d,EXTRACT(epoch FROM CAST(? AS DATE)) AS e", "1900-02-15", "0000-02-29", "2016-01-01", nil],
    ["SELECT DATE_TRUNC(mcs,CAST(? AS TIME(3))) AS v,EXTRACT(epoch FROM CAST(? AS TIME(9))) AS e,EXTRACT(iso_week_year FROM CAST(? AS TIME(9))) AS y", "00:00:00", "00:00:00.000000001", "23:59:59.123456789", nil],
    ["SELECT DATE_TRUNC(week_year,CAST(? AS TIMESTAMP(3))) AS v,LAST_DAY(?) AS d,EXTRACT(epoch FROM CAST(? AS TIMESTAMP(9))) AS e", "1969-12-31 23:59:59.999999999", "0000-02-29 00:00:00.000000001", "2016-01-01 12:34:56.123456789", nil]
  ]
  results = cases.flat_map do |sql, *values|
    statement = connection.prepare(sql)
    values.map { statement.execute(it, it, it) }
  end
  results << connection.execute("SELECT EXTRACT(epoch FROM TIME '00:00:00') AS v,EXTRACT(epoch FROM TIME '00:00:00.000000001') AS f,EXTRACT(epoch FROM DATE '-1000000000-01-01') AS d")
  lines = []
  results.each do |result|
    result.types.each_with_index { |type, index| lines << "M\t#{result.columns[index]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
    values = result.rows.first.map { it.nil? ? "null" : (it.is_a?(BigDecimal) ? it.to_s("F").delete_suffix(".0") : it.to_s) }
    lines << (["R"] + values).join("\t")
  end
  lines.join("\n") + "\n"
end
abort "Calendar JDBC parameters differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Calendar functions: 13 JDBC comparisons passed (reused bindings, declared scales, nulls, numeric precision and nanosecond epoch values)"

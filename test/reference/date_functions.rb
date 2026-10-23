# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

statements = []
fields = %w[YEAR MONTH QUARTER CENTURY MILLENNIUM WEEK ISO_WEEK DAY HOUR MINUTE SECOND MILLISECOND MICROSECOND NANOSECOND]
values = ["DATE '2000-02-29'", "DATE '-0400-01-31'", "DATE '0000-12-31'",
  "DATE '1000000000-12-31'", "DATE '-1000000000-01-01'",
  "TIME '23:59:59.999999999'", "TIMESTAMP '1999-12-31 23:59:59.123456789'"]
fields.product([-2_147_483_649, -2_147_483_648, -13, -1, 0, 1, 13, 2_147_483_647, 2_147_483_648], values).each do |field, count, value|
  statements << "SELECT DATEADD(#{field},#{count},#{value}) AS v;"
end
%w[MILLISECOND MICROSECOND NANOSECOND].product([-9_223_372_036_854_775_808, -9_223_372_036_854_775_807, 9_223_372_036_854_775_807], values).each do |field, count, value|
  statements << "SELECT DATEADD(#{field},#{count},#{value}) AS v;"
end
dates = ["-1000000000-01-01", "-1001-12-31", "-0100-12-31", "-0001-12-31", "0000-01-01", "0001-01-01", "1969-12-28", "1969-12-29", "2000-01-01", "2001-01-01", "1000000000-12-31"]
(fields + %w[DECADE EPOCH DAY_OF_YEAR DAY_OF_WEEK DOW ISO_DAY_OF_WEEK]).product(dates).each do |field, date|
  dates.each do |other|
    statements << "SELECT DATEDIFF(#{field},TIMESTAMP '#{date} 23:59:59.999999999',TIMESTAMP '#{other} 00:00:00.000000001') AS v;"
  end
end
aliases = %w[YEAR YY YYYY SQL_TSI_YEAR MONTH M MM SQL_TSI_MONTH DAY D DD SQL_TSI_DAY HOUR HH SQL_TSI_HOUR
  MINUTE MI N SQL_TSI_MINUTE SECOND S SS SQL_TSI_SECOND MILLISECOND MILLISECONDS MS MICROSECOND MICROSECONDS MCS
  NANOSECOND NS DAY_OF_YEAR DAYOFYEAR DY DOY ISO_DAY_OF_WEEK ISODOW ISO_WEEK ISO_WEEK_YEAR ISO_YEAR ISOYEAR
  DAY_OF_WEEK DAYOFWEEK WEEK WK WW SQL_TSI_WEEK WEEK_YEAR MILLENNIUM CENTURY DECADE QUARTER EPOCH DOW]
aliases.each do |field|
  statements << "SELECT DATEADD('#{field.downcase}',1,DATE '2000-01-01') AS a,DATEDIFF(#{field},DATE '1999-12-31',DATE '2000-01-01') AS d;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Date functions: #{statements.length} generated Java comparisons passed (fields, aliases, calendar boundaries, signed years, units and integer overflow)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "DateFunctionsParametersOracle.java"))
abort error unless status.success?
actual = H2.connect do |connection|
  counts = [1, -1, nil, BigDecimal("0.5"), BigDecimal("-0.5"), -0.5, 2_147_483_648]
  cases = [
    ["SELECT DATEADD(month,?,CAST(? AS DATE)) AS a,DATEDIFF(day,CAST(? AS DATE),CAST(? AS DATE)) AS d", "2000-01-31", "2000-02-01"],
    ["SELECT DATEADD(ns,?,CAST(? AS TIMESTAMP(9))) AS a,DATEDIFF(mcs,CAST(? AS TIMESTAMP(9)),CAST(? AS TIMESTAMP(9))) AS d", "2000-01-31 23:59:59.999999999", "2000-02-01 00:00:00.000000001"],
    ["SELECT DATEADD(second,?,CAST(? AS TIME(9))) AS a,DATEDIFF(second,CAST(? AS TIME(9)),CAST(? AS TIME(9))) AS d", "23:59:59.123456789", "00:00:00.000000001"]
  ]
  lines = []
  cases.each do |sql, first, second|
    statement = connection.prepare(sql)
    counts.each do |count|
      begin
        result = statement.execute(count, first, first, second)
        result.types.each_with_index { |type, index| lines << "M\t#{result.columns[index]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
        lines << (["R"] + result.rows.first.map { it.nil? ? "null" : it.to_s }).join("\t")
      rescue H2::Error => error
        lines << "E\t#{error.code}\t#{error.sql_state}"
      end
    end
  end
  lines.join("\n") + "\n"
end
abort "Date function JDBC parameters differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Date functions: 21 JDBC prepared comparisons passed (reused counts, nulls, decimal/float rounding, ranges, precision and scale)"

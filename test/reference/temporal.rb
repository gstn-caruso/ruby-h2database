# frozen_string_literal: true

require "open3"
require "date"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

statements = []
[-1_000_000_000, -400, -100, -4, -1, 0, 1, 4, 100, 400, 1582, 1600, 1900, 2000, 2024, 1_000_000_000].product((1..12).to_a, [1, 28, 29, 30, 31]).each do |year, month, day|
  literal = "DATE '#{year.negative? ? '-' : ''}#{year.abs.to_s.rjust(4, '0')}-#{month.to_s.rjust(2, '0')}-#{day.to_s.rjust(2, '0')}'"
  statements << "SELECT #{literal} AS d,DAY_OF_YEAR(#{literal}) AS doy,DAY_OF_WEEK(#{literal}) AS dow,#{literal}+1 AS next_day;"
end
[0, 1, 12, 23].product([0, 59], [0, 59], ["", ".000000001", ".1234567899", ".499999999", ".500000000", ".999999999"], [0, 1, 3, 6, 8, 9]).each do |hour, minute, second, fraction, scale|
  text = [hour, minute, second].map { it.to_s.rjust(2, "0") }.join(":") + fraction
  statements << "SELECT CAST(TIME '#{text}' AS TIME(#{scale})) AS t,CAST(TIMESTAMP '2000-02-28 #{text}' AS TIMESTAMP(#{scale})) AS ts;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Temporal values: #{statements.length} generated Java comparisons passed (Gregorian calendar, year bounds, invalid dates, nanoseconds and rounding)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "TemporalParametersOracle.java"))
abort error unless status.success?
actual = H2.connect do |connection|
  connection.execute("CREATE TABLE t(d DATE,t TIME(9),ts TIMESTAMP(9))")
  insert = connection.prepare("INSERT INTO t VALUES(?,?,?)")
  values = [
    [Date.new(2000, 2, 29), H2::TimeValue.parse("23:59:59.123456789"), Time.new(2000, 1, 2, 3, 4, Rational(5_123_456_789, 1_000_000_000), "+03:00")],
    [H2::DateValue.parse("0000-02-29"), H2::TimeValue.parse("00:00:00.000000001"), H2::TimestampValue.parse("-0400-02-29 00:00:00")],
    [nil, nil, nil]
  ]
  lines = values.map { "U\t#{insert.execute(*it).update_count}" }
  result = connection.execute("TABLE t ORDER BY d NULLS LAST")
  result.types.each_with_index { |type, index| lines << "M\t#{result.columns[index]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
  result.rows.each { |row| lines << (["R"] + row.map { it.nil? ? "null" : it.to_s }).join("\t") }
  lines.join("\n") + "\n"
end
abort "Temporal JDBC parameters differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Temporal values: JDBC LocalDate/LocalTime/LocalDateTime parameters match Ruby adapters, nulls, precision and scale"

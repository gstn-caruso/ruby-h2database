# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

samples = [
  ["YEAR", "1"], ["MONTH", "2"], ["DAY", "3"], ["HOUR", "4"], ["MINUTE", "5"], ["SECOND", "6.123456789"],
  ["YEAR TO MONTH", "1-2"], ["DAY TO HOUR", "1 2"], ["DAY TO MINUTE", "1 2:3"], ["DAY TO SECOND", "1 2:3:4.123456789"],
  ["HOUR TO MINUTE", "1:2"], ["HOUR TO SECOND", "1:2:3.123456789"], ["MINUTE TO SECOND", "1:2.123456789"]
]
declaration = lambda do |qualifier, precision = 18, scale = 9|
  fields = qualifier.split(" TO ")
  fields[0] += qualifier == "SECOND" ? "(#{precision},#{scale})" : "(#{precision})"
  fields[-1] += "(#{scale})" if fields.length > 1 && fields[-1] == "SECOND"
  "INTERVAL #{fields.join(' TO ')}"
end
statements = []
literals = samples.flat_map { |q, text| ["INTERVAL '#{text}' #{q}", "INTERVAL '-#{text}' #{q}"] }
literals.product(samples.map(&:first)).each do |value, qualifier|
  statements << "SELECT CAST(#{value} AS #{declaration.call(qualifier)}) AS v;"
end
samples.each do |qualifier, text|
  [-1, 0, 1, 99, 100, 999_999_999_999_999_999, 1_000_000_000_000_000_000].each do |leading|
    raw = text.sub(/\A\d+/, leading.to_s)
    statements << "SELECT INTERVAL '#{raw}' #{qualifier} AS v;"
  end
  [1, 2, 3, 18].product([0, 1, 3, 6, 8, 9]).each do |precision, scale|
    value = "INTERVAL '#{text.sub(/\A\d+/, '99')}' #{qualifier}"
    statements << "SELECT CAST(#{value} AS #{declaration.call(qualifier, precision, scale)}) AS v;"
  end
  ["0", "1", "-1", "1.5", "-1.5", "CAST(-0.5 AS DOUBLE)", "CAST(-0.5 AS REAL)", "99.999999999", "999999999999999999", "1000000000000000000"].each do |number|
    statements << "SELECT CAST(#{number} AS #{declaration.call(qualifier)}) AS v;"
  end
end
literals.product(literals, %w[+ - /]).each do |left, right, operator|
  statements << "SELECT #{left} #{operator} #{right} AS v;"
end
literals.product(literals).each do |left, right|
  statements << "SELECT #{left}=#{right} AS same,#{left}<#{right} AS lower;"
  statements << "SELECT #{left} AS v UNION SELECT #{right};"
end
literals.product(["0", "1", "-1", "0.5", "3"], %w[* /]).each do |value, number, operator|
  statements << "SELECT #{value} #{operator} #{number} AS v;"
end
fields = %w[YEAR MONTH DAY DAY_OF_YEAR HOUR MINUTE SECOND MILLISECOND MICROSECOND NANOSECOND EPOCH QUARTER]
literals.product(fields).each { |value, field| statements << "SELECT EXTRACT(#{field} FROM #{value}) AS v;" }
["999999999999999999.999999999", "-10000000000.000000001", "9223372036.854775808"].product(fields).each do |text, field|
  statements << "SELECT EXTRACT(#{field} FROM INTERVAL '#{text}' SECOND) AS v;"
end
literals.product(["DATE '2000-01-31'", "TIME '23:00:00.123456789'", "TIMESTAMP '2000-01-31 23:00:00.123456789'"], %w[+ -]).each do |interval, datetime, operator|
  statements << "SELECT #{datetime} #{operator} #{interval} AS v;"
end
samples.product(["DATE '2000-01-31'", "TIMESTAMP '2000-01-31 23:00:00.123456789'"]).each do |(q, text), datetime|
  statements << "SELECT #{datetime}+INTERVAL '#{text.sub(/\A\d+/, '999999999999999999')}' #{q} AS v;"
end
dates = ["DATE '-1000000000-01-01'", "DATE '0000-02-29'", "DATE '2000-01-31'", "DATE '2001-02-28'", "DATE '1000000000-12-31'", "TIME '00:00:00'", "TIME '23:59:59.999999999'", "TIMESTAMP '2000-01-31 23:59:59.999999999'"]
dates.product(dates).each do |left, right|
  statements << "SELECT #{left}-#{right} AS v;"
  samples.map(&:first).each do |qualifier|
    next if qualifier.include?("YEAR") || qualifier == "MONTH"

    statements << "SELECT (#{left}-#{right}) #{declaration.call(qualifier).delete_prefix('INTERVAL ')} AS v;"
  end
end
dates.reject { it.start_with?("TIME ") }.product(dates.reject { it.start_with?("TIME ") }, %w[YEAR MONTH] + ["YEAR TO MONTH"]).each do |left, right, qualifier|
  statements << "SELECT (#{left}-#{right}) #{declaration.call(qualifier).delete_prefix('INTERVAL ')} AS v;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Intervals: #{statements.length} generated Java comparisons passed (13 qualifiers, casts, families, arithmetic, precision, extraction and datetime differences)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "IntervalParametersOracle.java"))
abort error unless status.success?
actual = H2.connect do |connection|
  qualifiers = samples.map(&:first)
  remaining = [0, 0, 0, 0, 0, 123456789, 2, 2, 123, 7384123456789, 2, 123123456789, 2123456789]
  schema = qualifiers.each_with_index.map { |q, index| "c#{index} #{declaration.call(q, 5, 9)}" }
  connection.execute("CREATE TABLE t(id INT PRIMARY KEY,#{schema.join(',')})")
  statement = connection.prepare("INSERT INTO t VALUES(#{(['?'] * 14).join(',')})")
  lines = (0...4).map do |row|
    values = qualifiers.each_with_index.map { |q, index| row == 3 ? nil : H2::IntervalValue.new(q, row == 1, row == 2 ? 0 : 1, row == 2 ? 0 : remaining[index]) }
    "U\t#{statement.execute(row, *values).update_count}"
  end
  results = [connection.execute("SELECT #{(0...13).map { "c#{it}" }.join(',')} FROM t ORDER BY id")]
  results << connection.prepare("SELECT CAST(? AS INTERVAL DAY(5) TO SECOND(3)) AS v").execute(H2::IntervalValue.new("DAY TO SECOND", true, 1, 7384123456789))
  results << connection.execute("SELECT (DATE '2001-02-01'-DATE '2000-01-01') YEAR AS forced,INTERVAL '1.999999999' SECOND(2,0) AS literal,AVG(c2) AS average,SUM(c2) AS total FROM t")
  results.each do |result|
    result.types.each_with_index { |type, index| lines << "M\t#{result.columns[index]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
    result.rows.each { |row| lines << (["R"] + row.map { it.nil? ? "null" : it.to_s }).join("\t") }
  end
  lines.join("\n") + "\n"
end
abort "Interval JDBC parameters differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Intervals: JDBC bindings for all 13 qualifiers, signs, zero/null values, casts, precision/scales, aggregates and forced-difference metadata passed"

# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

arrays = ["ARRAY[]", "ARRAY[NULL]", "ARRAY[1]", "ARRAY[1,2]", "ARRAY[1,NULL]", "ARRAY[NULL,1]",
  "ARRAY[1,NULL,2]", "ARRAY[1,2,3]", "ARRAY['1','2']", "ARRAY['a','b']", "ARRAY[1.00,2.25]",
  "ARRAY[ARRAY[1]]", "ARRAY[ARRAY[1,2],ARRAY[3]]", "ARRAY[X'00',X'ff']",
  "ARRAY[TIME WITH TIME ZONE '12:00:00+03',TIME WITH TIME ZONE '09:00:00Z']", "CAST(NULL AS INT ARRAY)"]
statements = ["SET TIME ZONE 'UTC';"]
arrays.product(arrays, ["=", "<>", "<", ">", "<=", ">=", "IS DISTINCT FROM", "IS NOT DISTINCT FROM", "||"]).each do |a, b, operator|
  statements << "SELECT #{a} #{operator} #{b} AS v;"
end
targets = ["INT ARRAY[0]", "INT ARRAY[1]", "INT ARRAY[3]", "VARCHAR(3) ARRAY[2]", "NUMERIC(5,2) ARRAY",
  "DOUBLE PRECISION ARRAY", "INT ARRAY[2] ARRAY[2]", "VARCHAR", "INT"]
arrays.product(targets).each { |a, type| statements << "SELECT CAST(#{a} AS #{type}) AS v;" }
indices = ["NULL", "-2147483648", "-1", "0", "1", "2", "3", "4", "1.5", "2147483647", "2147483648"]
arrays.product(indices).each do |a, index|
  statements << "SELECT #{a}[#{index}] AS v;"
  statements << "SELECT TRIM_ARRAY(#{a},#{index}) AS v;"
end
arrays.first(8).product(indices.first(8), indices.first(8)).each do |a, first, last|
  statements << "SELECT ARRAY_SLICE(#{a},#{first},#{last}) AS v;"
end
arrays.product(["NULL", "1", "'a'", "ARRAY[1]", "ARRAY[1,2]"]).each do |a, value|
  statements << "SELECT ARRAY_CONTAINS(#{a},#{value}) AS v;"
end
arrays.each do |a|
  statements << "SELECT CARDINALITY(#{a}) AS cardinality,ARRAY_MAX_CARDINALITY(#{a}) AS maximum;"
end
["NULL", "1", "'a'", "ROW(1,2)"].each do |value|
  statements << "SELECT CARDINALITY(#{value}) AS v;"
  statements << "SELECT ARRAY_MAX_CARDINALITY(#{value}) AS v;"
  statements << "SELECT ARRAY_CONTAINS(#{value},NULL) AS v;"
  statements << "SELECT TRIM_ARRAY(#{value},0) AS v WHERE FALSE;"
end
family = ["VALUES ARRAY[],ARRAY[1],ARRAY[1],NULL", "VALUES ARRAY[1,2],ARRAY[1,NULL]", "VALUES ARRAY[1.00],ARRAY[2.25]",
  "VALUES ARRAY[ARRAY[1,2]],ARRAY[ARRAY[3]]", "SELECT CAST(NULL AS INT ARRAY) AS c1"]
family.product(family, ["UNION", "UNION ALL", "INTERSECT", "EXCEPT"]).each do |a, b, operator|
  statements << "(#{a}) #{operator} (#{b}) ORDER BY 1;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Arrays: #{statements.length} generated Java comparisons passed (nested types, null comparisons, casts, cardinalities, indexes, functions and set operations)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "ArrayParametersOracle.java"))
abort error unless status.success?
differences, transcript = expected.lines.partition { it.start_with?("D\t") }
abort "Missing RangeIndex NULL-bound reference evidence" unless differences == ["D\tRangeIndex NULL bound\t50000\n"]
expected = transcript.join
actual = H2.connect do |connection|
  lines = []
  ["SELECT ARRAY[?]", "SELECT ARRAY[?,NULL]", "SELECT ARRAY[CAST(? AS INT)]", "SELECT ?[1]",
    "SELECT TRIM_ARRAY(?,0)", "SELECT ARRAY_SLICE(?,1,2)", "SELECT ARRAY_LENGTH(?)", "SELECT ARRAY_MAX_CARDINALITY(?)"].each do |sql|
    begin
      connection.prepare(sql)
      lines << "P\t#{sql}\tOK"
    rescue H2::Error => error
      lines << "P\t#{sql}\t#{error.code}\t#{error.sql_state}"
    end
  end
  dump = lambda do |statement, *values|
    result = statement.execute(*values)
    result.types.each_with_index do |type, i|
      precision = type.precision || {"INTEGER" => 32, "BIGINT" => 64}.fetch(type.name)
      lines << "M\t#{result.columns[i]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each { |row| lines << (["R"] + row.map { it.nil? ? "null" : it.to_s }).join("\t") }
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  statement = connection.prepare("SELECT CARDINALITY(CAST(? AS INT ARRAY)) AS n")
  dump.call(statement, Array.new(65_536))
  dump.call(statement, Array.new(65_537))
  statement = connection.prepare("SELECT CAST(? AS INTEGER ARRAY[2]) AS a,ARRAY_GET(CAST(? AS INTEGER ARRAY),?) AS e")
  dump.call(statement, [1, nil, 3], [3, 4], 1)
  dump.call(statement, nil, nil, 1)
  dump.call(statement, [], [3, 4], 0)
  dump.call(statement, [1], [3, 4], 3)
  statement = connection.prepare("SELECT ? AS a")
  [[], [1, nil, 3], ["a", "bbb"], [[1, 2], [3]], [H2::TimeTimeZoneValue.parse("12:00:00.000000001+03"), nil]].each { dump.call(statement, it) }
  statement = connection.prepare("SELECT ARRAY_SLICE(CAST(? AS INT ARRAY),?,?) AS a")
  dump.call(statement, [1, 2, 3], 2, 3)
  dump.call(statement, nil, "bad", "bad")
  dump.call(statement, [1], "bad", nil)
  dump.call(statement, [1, 2], 3, 2)
  statement = connection.prepare("SELECT ARRAY[?,CAST(? AS BIGINT)] AS a,ARRAY_LENGTH(CAST(? AS INT ARRAY)) AS n")
  dump.call(statement, 1, 2, [1, 2, 3])
  dump.call(statement, nil, nil, nil)
  statement = connection.prepare("SELECT ARRAY(SELECT x FROM SYSTEM_RANGE(1,3) WHERE x<=?) AS a")
  dump.call(statement, 2)
  result = statement.execute(nil)
  unless result.types.first.name == "BIGINT ARRAY" && result.types.first.precision == 65_536 && result.rows.first.first.values.empty?
    abort "Native NULL-bound range must produce a typed empty array"
  end
  statement = connection.prepare("SELECT ARRAY(SELECT x FROM (VALUES 1,2,3) t(x) WHERE x<=?) AS a")
  dump.call(statement, 2)
  dump.call(statement, nil)
  connection.execute("CREATE TABLE saved(a INT ARRAY DEFAULT CAST(? AS INT ARRAY))", [1, nil, 3])
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved"))
  lines.join("\n") + "\n"
end
abort "Array JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Arrays: 21 JDBC executions and 8 preparation checks passed (cardinality limits, reused/nested/offset array bindings, nulls, indexes, lazy slices, constructor types, query parameters and saved defaults)"
puts "Reference limitation: Java RangeIndex.find reads a NULL index bound as a long and fails with 50000; native filtering returns the independently verified typed empty array"

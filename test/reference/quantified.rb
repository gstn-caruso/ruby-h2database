# frozen_string_literal: true

require "open3"

operators = ["=", "<>", "<", ">", "<=", ">=", "IS DISTINCT FROM", "IS NOT DISTINCT FROM"]
lefts = ["NULL", "1", "2", "'1'", "'bad'", "ARRAY[1,NULL]", "ROW(1)", "ROW(1,NULL)", "ROW(1,2)"]
arrays = ["NULL", "ARRAY[]", "CAST(NULL AS INT ARRAY)", "1", "ARRAY[1,2]", "ARRAY[NULL,1]", "ARRAY['1','bad']",
  "ROW(1)", "ROW(1,2)", "ARRAY[ARRAY[1,NULL],ARRAY[2,3]]", "ARRAY[1.00,2.25]", "ARRAY[DATE '2000-01-01']",
  "ARRAY[TRUE,FALSE]", "ARRAY[X'00',X'01']", "ARRAY[ARRAY[NULL,1]]"]
queries = ["VALUES 1,2,NULL", "VALUES '1','bad'", "SELECT 1 WHERE FALSE", "VALUES (1,2),(2,NULL)",
  "VALUES ARRAY[1,NULL],ARRAY[2,3]", "VALUES ROW(1),ROW(2)", "SELECT * FROM UNNEST(COALESCE(ARRAY[1,2],NULL))",
  "SELECT v FROM (VALUES 2,1,NULL) t(v) ORDER BY v DESC LIMIT 2", "VALUES 1 UNION VALUES 2", "SELECT"]
statements = lefts.product(arrays, operators, ["ANY", "ALL"], [false, true]).map do |left, array, operator, quantifier, negate|
  condition = "#{left} #{operator} #{quantifier}(#{array})"
  "SELECT #{negate ? 'NOT(' + condition + ')' : condition} AS v;"
end
statements.concat(lefts.product(queries, operators, ["ANY", "ALL"], [false, true]).map do |left, query, operator, quantifier, negate|
  condition = "#{left} #{operator} #{quantifier}(#{query})"
  "SELECT #{negate ? 'NOT(' + condition + ')' : condition} AS v;"
end)
families = [
  ["CAST('a' AS CHAR(3))", "ARRAY['a','b',NULL]"],
  ["'a'", "CAST(ARRAY['a','b',NULL] AS CHAR(3) ARRAY)"],
  ["X'00'", "ARRAY[X'00',X'ff',NULL]"],
  ["DATE '2000-02-29'", "ARRAY[DATE '2000-01-01',DATE '2000-02-29',NULL]"],
  ["TIME WITH TIME ZONE '12:00:00+03'", "ARRAY[TIME WITH TIME ZONE '09:00:00Z',NULL]"],
  ["INTERVAL '1' YEAR", "ARRAY[INTERVAL '12' MONTH,NULL]"],
  ["UUID '00000000-0000-0000-0000-000000000001'", "ARRAY[UUID '00000000-0000-0000-0000-000000000001',NULL]"],
  ["ROW(1,NULL)", "ARRAY[ROW(1,NULL),ROW(2,3)]"]
]
families.product(operators, ["ANY", "ALL", "SOME"]).each do |(left, array), operator, quantifier|
  statements << "SELECT #{left} #{operator} #{quantifier}(#{array}) AS v;"
  statements << "SELECT v #{operator} #{quantifier}(a) AS v FROM (VALUES (#{left},#{array}),(NULL,#{array})) t(v,a);"
  statements << "SELECT #{left} #{operator} #{quantifier}(SELECT * FROM UNNEST(#{array})) AS v;"
  statements << "SELECT CASE v WHEN #{operator} #{quantifier}(a) THEN 1 ELSE 2 END AS c FROM (VALUES (#{left},#{array}),(NULL,#{array})) t(v,a);"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Quantified comparisons: #{statements.length} generated Java comparisons passed (arrays, scalars, rows, query types/order/pagination, nulls, all operators, NOT, SOME, CASE and component conversions)"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "QuantifiedOracle.java"))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    executions += 1
    result = statement.execute(*values)
    result.types.each_with_index do |type, i|
      precision = type.precision || {"BOOLEAN" => 1, "INTEGER" => 32}.fetch(type.name)
      lines << "M\t#{result.columns[i]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      values = row.map { it.nil? ? "null" : ([true, false].include?(it) ? it.to_s.upcase : it.to_s) }
      lines << (["R"] + values).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  statement = connection.prepare("SELECT ?=ANY(?),? IS NOT DISTINCT FROM ALL(?),?>ALL(VALUES (?),(?))")
  [[2, [1, 2], nil, [1, nil], 3, 1, 2], [nil, [], nil, [nil], 3, 1, nil], [1, 1, nil, nil, 0, 1, 2],
    [2, ["1", "bad"], 1, [1], 3, 1, 2]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT ?=ANY(CAST(? AS NUMERIC(5,2) ARRAY)) AS a,?=ALL(SELECT * FROM UNNEST(?)) AS q")
  [[BigDecimal("1.25"), [BigDecimal("1.25"), nil], 1, [1, 2]], [nil, [], 1, []], [2, [BigDecimal("1.25"), nil], 1, [1, 1]],
    [1, nil, nil, [nil]], [1, ["bad"], 1, []]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT CAST(? AS TIME(9))=ANY(ARRAY[CAST(CURRENT_DATE AS TIMESTAMP)+TIME '12:00:00']) AS a")
  ["12:00:00", "00:00:00", "12:00:00.000000001", nil].each { dump.call(statement, it && H2::TimeValue.parse(it)) }
  statement = connection.prepare("SELECT CASE ? WHEN =ANY(?) THEN 1 WHEN IS NOT DISTINCT FROM ALL(?) THEN 2 ELSE 3 END AS c")
  [[1, [1, 2], [1]], [nil, [1, nil], [nil]], [2, [], [2]], [2, nil, [1]]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT ?>ANY(SELECT c1 FROM (VALUES 2,1) ORDER BY c1 DESC LIMIT ?) AS q")
  dump.call(statement, 2, 1)
  dump.call(statement, 2, 2)
  connection.execute("CREATE TABLE source(v INT)")
  connection.execute("INSERT INTO source VALUES(1),(2)")
  connection.execute("CREATE TABLE saved(q BOOLEAN DEFAULT ?>ALL(SELECT v FROM source))", 3)
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  connection.execute("INSERT INTO source VALUES(4)")
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved"))
  connection.execute("SET TIME ZONE '+18'")
  date = connection.execute("SELECT CURRENT_DATE").rows.first.first.to_s
  array = "ARRAY[TIMESTAMP '#{date} 12:00:00']"
  connection.execute("CREATE TABLE clock(f BOOLEAN DEFAULT TIME '12:00:00'=ANY(#{array}),d BOOLEAN DEFAULT ?=ANY(#{array}),c INT DEFAULT CASE TIME '12:00:00' WHEN =ANY(#{array}) THEN 1 ELSE 2 END)", H2::TimeValue.parse("12:00:00"))
  connection.execute("INSERT INTO clock DEFAULT VALUES")
  connection.execute("SET TIME ZONE '-18'")
  connection.execute("INSERT INTO clock DEFAULT VALUES")
  dump.call(connection.prepare("TABLE clock"))
  lines.join("\n") + "\n"
end
abort "Quantified JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Quantified comparisons: #{executions} JDBC executions passed (reused arrays/scalars/nulls, metadata, CASE, query pagination, errors and captured query/session-date defaults)"

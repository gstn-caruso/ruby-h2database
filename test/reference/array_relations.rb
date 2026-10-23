# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
families = [
  "(VALUES (3,1,'a'),(NULL,2,'b'),(1,3,'a'),(3,4,'b'),(2,5,'a')) t(v,k,g)",
  "(VALUES (1.00,1,'a'),(NULL,2,'b'),(2.25,3,'a'),(1.00,4,'b')) t(v,k,g)",
  "(VALUES ('a',1,'a'),(NULL,2,'b'),('b',3,'a'),('a',4,'b')) t(v,k,g)",
  "(VALUES (X'00',1,'a'),(NULL,2,'b'),(X'ff',3,'a'),(X'00',4,'b')) t(v,k,g)",
  "(VALUES (ARRAY[1,2],1,'a'),(NULL,2,'b'),(ARRAY[1,NULL],3,'a'),(ARRAY[1,2],4,'b')) t(v,k,g)",
  "(VALUES (ROW(1,'a'),1,'a'),(NULL,2,'b'),(ROW(2,'b'),3,'a'),(ROW(1,'a'),4,'b')) t(v,k,g)",
  "(VALUES (TIME WITH TIME ZONE '12:00:00+03',1,'a'),(NULL,2,'b'),(TIME WITH TIME ZONE '09:00:00Z',3,'a'),(TIME WITH TIME ZONE '10:00:00Z',4,'b')) t(v,k,g)"
]
orders = ["", " ORDER BY v", " ORDER BY v DESC NULLS LAST", " ORDER BY k DESC", " ORDER BY g,k DESC", " ORDER BY 1", " ORDER BY NULL"]
filters = ["", " FILTER(WHERE v IS NOT NULL)", " FILTER(WHERE k<4)", " FILTER(WHERE NULL)", " FILTER(WHERE FALSE)"]
statements = families.product(["", "DISTINCT "], orders, filters).flat_map do |family, distinct, order, filter|
  call = "ARRAY_AGG(#{distinct}v#{order})#{filter}"
  ["SELECT #{call} AS a FROM #{family};", "SELECT g,#{call} AS a FROM #{family} GROUP BY g ORDER BY g;",
    "SELECT #{call} AS a FROM #{family} WHERE FALSE;"]
end
expressions = ["v+1.5", "v-1.5", "v*1.5", "v/1.5", "COALESCE(v,1.25)", "CAST(v AS NUMERIC(8,3))"]
expressions.product(["", "DISTINCT "], ["", " ORDER BY v DESC"], ["", " FILTER(WHERE v<>0)"]).each do |expr, distinct, order, filter|
  statements << "SELECT ARRAY_AGG(#{distinct}#{expr}#{order})#{filter} AS a FROM (VALUES 0,1,2,NULL,-1) t(v);"
end
arrays = ["ARRAY[]", "ARRAY[1,NULL,2]", "NULL", "CAST(NULL AS INT ARRAY)", "ARRAY[1.00,2.25]", "1", "ROW(1,'a')",
  "ARRAY[ARRAY[1,2],ARRAY[3]]", "ARRAY[1]||ARRAY[2]", "(SELECT ARRAY[1,2])", "ARRAY(SELECT x FROM SYSTEM_RANGE(1,3))",
  "(SELECT ARRAY_AGG(x ORDER BY x) FROM SYSTEM_RANGE(1,3))", "COALESCE(ARRAY[1],ARRAY[2])", "CAST(ARRAY['a','b'] AS CHAR(3) ARRAY)", "ROW(X'00','a')"]
arrays.product(arrays, ["", " WITH ORDINALITY"]).each do |a, b, ordinality|
  statements << "SELECT * FROM UNNEST(#{a},#{b})#{ordinality};"
end
arrays.product(["", "DISTINCT "], ["", " ORDER BY c1"]).each do |array, distinct, order|
  statements << "SELECT ARRAY_AGG(#{distinct}c1#{order}) AS a FROM UNNEST(#{array});"
end
%w[COUNT SUM AVG MIN MAX].product(["", "DISTINCT "], filters).each do |name, distinct, filter|
  statements << "SELECT #{name}(#{distinct}v)#{filter} AS v FROM (VALUES (0,1),(1,2),(NULL,3),(2,4),(-1,5)) t(v,k);"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Array relations: #{statements.length} generated Java comparisons passed (grouped/ordered/distinct/filtered arrays, scalar filters, numeric component types, UNNEST templates, padding and ordinality)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "ArrayRelationsOracle.java"))
abort error unless status.success?
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    result = statement.execute(*values)
    result.types.each_with_index do |type, i|
      precision = type.precision || {"NULL" => 1, "INTEGER" => 32, "BIGINT" => 64}.fetch(type.name)
      lines << "M\t#{result.columns[i]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      values = row.each_with_index.map do |value, i|
        value.nil? ? "null" : (value.is_a?(BigDecimal) ? H2::ArrayType.decimal_text(value, result.types[i].scale) : value.to_s)
      end
      lines << (["R"] + values).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  statement = connection.prepare("SELECT ARRAY_AGG(CAST(? AS NUMERIC(5,2))+v ORDER BY k DESC) FILTER(WHERE v>?) AS a FROM (VALUES (0,1),(1,2),(2,3),(3,4)) t(v,k)")
  [[BigDecimal("1.25"), 0], [nil, 0], [BigDecimal("-1.25"), 2], [BigDecimal("1.25"), nil]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT * FROM UNNEST(?,CAST(? AS INT ARRAY)) WITH ORDINALITY")
  [[[1, 2], [3]], [nil, []], [["a", "b"], [3, 4, 5]], ["scalar", [3, 4]]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT ARRAY_AGG(c1 ORDER BY c1) AS a FROM UNNEST(?)")
  [[2, 1, 2], [], nil].each { dump.call(statement, it) }
  statement = connection.prepare("SELECT * FROM UNNEST(CAST(? AS NUMERIC(6,3) ARRAY)) WITH ORDINALITY")
  dump.call(statement, [BigDecimal("1.250"), nil, BigDecimal("2.125")])
  dump.call(statement, nil)
  statement = connection.prepare("SELECT COUNT(*) FILTER(WHERE v>?) AS n,SUM(v) FILTER(WHERE v>?) AS s FROM (VALUES 0,1,2,3) t(v)")
  dump.call(statement, 1, 1)
  dump.call(statement, nil, nil)
  statement = connection.prepare("SELECT CARDINALITY(ARRAY_AGG(x)) AS n FROM SYSTEM_RANGE(1,CAST(? AS INT))")
  [0, 65_536, 65_537].each { dump.call(statement, it) }
  connection.execute("CREATE TABLE source(v INT)")
  connection.execute("INSERT INTO source VALUES(1),(2)")
  connection.execute("CREATE TABLE saved(a INT ARRAY DEFAULT (SELECT ARRAY_AGG(v ORDER BY v DESC) FILTER(WHERE v>?) FROM source))", 1)
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  connection.execute("INSERT INTO source VALUES(3)")
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved"))
  lines.join("\n") + "\n"
end
abort "Array relation JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Array relations: 19 JDBC executions passed (reused filters/order parameters, UNNEST templates and ordinality, numeric precision, nulls, aggregation limits and captured query defaults)"

# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

statements = []
["UNION ALL", "UNION", "EXCEPT", "INTERSECT"].product([0, 1, 3, 5], [1, 2, 3], [1, 3, 6, 10]).each do |operator, seed, step, bound|
  statements << "WITH RECURSIVE r(n) AS (VALUES #{seed},#{seed} #{operator} SELECT n+#{step} FROM r WHERE n<#{bound}) TABLE r ORDER BY n;"
end
[1, 2, 4].product(["x", "😀", "("]).each do |bound, prefix|
  statements << "WITH RECURSIVE r(n,s) AS (VALUES(1,'#{prefix}') UNION ALL SELECT n+1,s||'a' FROM r WHERE n<#{bound}) TABLE r ORDER BY n;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Common tables: #{statements.length} generated Java comparisons passed (frontiers, duplicates, set operators, strings and bounds)"

prepared = [
  "WITH RECURSIVE r(n) AS (SELECT ? UNION ALL SELECT n+? FROM r WHERE n<?) TABLE r",
  "WITH RECURSIVE r(n) AS (SELECT CAST(? AS INT) UNION ALL SELECT n+CAST(? AS INT) FROM r WHERE n<?) TABLE r",
  "WITH RECURSIVE t1(f1,f2) AS (SELECT CAST(? AS INT),CAST(? AS VARCHAR(15)) UNION ALL SELECT f1+CAST(? AS INT),CAST(CAST(? AS VARCHAR)||f2 AS VARCHAR(15)) FROM t1 WHERE f1<4),t2(g1,g2) AS (SELECT CAST(? AS INT),CAST(? AS VARCHAR(15)) UNION ALL SELECT g1+1,CAST('b'||g2 AS VARCHAR(15)) FROM t2 WHERE g1<4) SELECT f1,f2,g1,g2 FROM t1 JOIN t2 ON f1=g1 ORDER BY f1",
  "WITH q(x) AS (SELECT ?) TABLE q"
]
bindings = [
  [[10, 2, 14], [100, 3, 103], [nil, 2, 14]],
  [[10, 2, 14], [100, 3, 103], [nil, 2, 14]],
  [[1, "a", 1, "a", 1, "b"], [2, "x", 1, "y", 2, "z"]],
  [[1], [2]]
]
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "CTEParametersOracle.java"), *prepared)
abort error unless status.success?
encode = ->(value) { [value.to_s].pack("m0") }
lines = []
H2.connect do |connection|
  prepared.each_with_index do |sql, index|
    statement = connection.prepare(sql)
    bindings[index].each_with_index do |values, run|
      lines << "CASE #{index}/#{run}"
      begin
        result = statement.execute(*values)
        lines << (["H"] + result.columns.zip(result.types).map { |name, type| "#{encode.call(name)}:#{type.name}" }).join("\t")
        result.rows.each { |row| lines << (["R"] + row.map { it.nil? ? "N" : "V#{encode.call(it)}" }).join("\t") }
      rescue H2::Error => exception
        lines << "E\t#{exception.code}\t#{exception.sql_state}"
      end
    end
  end
end
actual = lines.join("\n") + "\n"
abort "CTE prepared results differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Common tables: 10 JDBC prepared comparisons passed (reused parameters, inferred/cast metadata, nested recursion and null seeds)"

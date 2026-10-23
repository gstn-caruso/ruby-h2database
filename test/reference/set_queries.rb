# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

families = [
  ["VALUES NULL,1,1,2", "VALUES 2,3,NULL", "VALUES 1,1 LIMIT 2", "SELECT CAST(1 AS BIGINT) AS c1",
    "VALUES 1.00,2.25,NULL", "SELECT 1 AS c1 WHERE FALSE"],
  ["VALUES 'a','a','b',NULL", "SELECT CAST('a' AS CHAR(3)) AS c1", "VALUES '😀','\uE000',''", "VALUES 'b','a' ORDER BY 1 DESC"],
  ["VALUES X'00',X'ff',NULL", "VALUES X'',X'00',X'0000'", "SELECT CAST(X'00' AS BINARY(3)) AS c1", "VALUES X'ff',X'ff' LIMIT 2"],
  ["VALUES(ROW(1,NULL)),(ROW(1,NULL)),(ROW(2,'a'))", "VALUES(ROW(2,'a')),(ROW(NULL,'b'))", "VALUES(ROW(1,NULL)),(ROW(1,NULL)) LIMIT 2"],
  ["VALUES UUID '00000000-0000-0000-0000-000000000000',UUID 'ffffffff-ffff-ffff-ffff-ffffffffffff'",
    "SELECT CAST(NULL AS UUID) AS c1", "VALUES UUID '00000000-0000-0000-0000-000000000000',UUID '00000000-0000-0000-0000-000000000000' LIMIT 2"]
]
operators = ["UNION", "UNION ALL", "INTERSECT", "EXCEPT"]
statements = families.flat_map do |family|
  family.product(family, operators).map { |a, b, operator| "(#{a}) #{operator} (#{b}) ORDER BY 1;" }
end
a, b, c = ["VALUES 1,1,2,NULL", "VALUES 2,3,NULL", "VALUES 1,3"]
operators.product(operators).each do |first, second|
  statements << "#{a} #{first} #{b} #{second} #{c} ORDER BY 1;"
  statements << "(#{a} #{first} #{b}) #{second} #{c} ORDER BY 1;"
  statements << "#{a} #{first} (#{b} #{second} #{c}) ORDER BY 1;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?

puts "Set queries: #{statements.length} generated Java comparisons passed (duplicates, nulls, coercion, branch pagination and operator precedence)"

prepared = ["?", "(?)", "+?", "-?"].map { "SELECT 2 AS n UNION ALL SELECT 1 ORDER BY #{it}" }
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "SetParametersOracle.java"), *prepared)
abort error unless status.success?
actual = H2.connect do |connection|
  prepared.flat_map do |sql|
    [1, -1, nil].map do |value|
      label = "#{sql} [#{value.nil? ? 'null' : value}]:"
      begin
        label + connection.execute(sql, value).rows.map { " #{it.first}" }.join
      rescue H2::Error => exception
        "#{label} ERROR #{exception.code}"
      end
    end
  end.join("\n") + "\n"
end
abort "Prepared set ordering differs:\nJava: #{expected}\nRuby: #{actual}" unless actual == expected

puts "Set queries: 12 JDBC prepared-parameter ordering comparisons passed"

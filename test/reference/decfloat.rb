# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

samples = ['0', '1', '-1', '1.25', '-1.25', '0.1', '1e100', '-3e-100', 'Infinity', '-Infinity', 'NaN', nil]
cast = ->(value, precision) { "CAST(#{value.nil? ? 'NULL' : "'#{value}'"} AS DECFLOAT(#{precision}))" }
statements = []
samples.product(samples, %w[+ - * / %]).each do |a, b, operator|
  left, right = cast.call(a, 5), cast.call(b, 3)
  statements << "SELECT #{left}#{operator}#{right} AS v;"
  statements << "SELECT a#{operator}b AS v FROM (VALUES (#{left},#{right}),(#{left},#{right})) t(a,b);"
end
types = ['TINYINT', 'SMALLINT', 'INT', 'BIGINT', 'NUMERIC(10,2)', 'REAL', 'DOUBLE', 'DECFLOAT(4)', 'VARCHAR', 'BOOLEAN']
types.product(samples, %w[+ - * / %]).each do |type, sample, operator|
  other = type == 'BOOLEAN' ? 'TRUE' : "CAST('2' AS #{type})"
  value = cast.call(sample, 5)
  statements << "SELECT #{value}#{operator}#{other} AS v;"
  statements << "SELECT #{other}#{operator}#{value} AS v;"
end
samples.each do |sample|
  value = cast.call(sample, 8)
  statements << "SELECT ABS(#{value}) AS a,SIGN(#{value}) AS s,-#{value} AS n;"
  %w[SUM AVG MIN MAX].product(['', 'DISTINCT '], ['', ' FILTER(WHERE k<3)', ' FILTER(WHERE FALSE)']).each do |name, distinct, filter|
    statements << "SELECT #{name}(#{distinct}v)#{filter} AS v FROM (VALUES (#{value},1),(#{value},2),(NULL,3),(CAST(1 AS DECFLOAT(8)),4)) t(v,k);"
  end
end
['1E1', '1.2300E100', '1E-100', '0E100', '-0E100', '9.999E100', '1E+9'].each do |value|
  statements << "SELECT #{value},#{value} IS OF(DECFLOAT) AS d,JSON_ARRAY(#{value}) AS j;"
  statements << "SELECT JSON_ARRAY(SELECT v FROM (VALUES #{value}) t(v)) AS j;"
end
['0.000001', '0.0000001', '9.995', '9.999', '-9.995', '99999', '1e100', '1e-100'].product([1,2,3,5]).each do |value, precision|
  expression = cast.call(value, precision)
  statements << "SELECT #{expression};"
end
['1', '8', '16', '64', '125', '9.995', '-9.995'].product(['2', '3', '8', '16', '64', '999'], [1,2,3,5]).each do |a, b, precision|
  statements << "SELECT #{cast.call(a, precision)}/#{cast.call(b, precision)} AS v;"
end
['１２.٣٤', '١٢e٣', '𝟙', "\t1.25\n", '  +Infinity ', '+NaN', '-NaN', 'inf', 'infinity', '1e', '1e2147483647', '1e-2147483647'].each do |text|
  statements << "SELECT CAST('#{text.gsub("\t", ' ').gsub("\n", ' ')}' AS DECFLOAT(8)) AS v;"
end
[
  "SELECT (1E99999+1) IS OF(DECFLOAT) AS v;",
  "SELECT (1E100000+1) IS OF(DECFLOAT) AS v;",
  "SELECT 1E200001+1 AS v;",
  "SELECT CAST('1e-2147483647' AS DECFLOAT)*CAST('0.1' AS DECFLOAT) AS v;",
  "SELECT CAST('1e2147483647' AS DECFLOAT)*CAST('10' AS DECFLOAT) AS v;",
  "SELECT CAST('1e2147483647' AS DECFLOAT)*CAST('100' AS DECFLOAT) AS v;",
  "SELECT CAST('100e2147483647' AS DECFLOAT) AS v;"
].each { statements << it }
['1E-2147483648', '1E2147483649', '1E9999999999999999999999', '10E2147483647'].each do |value|
  statements << "SELECT #{value} AS v;"
end
['NULL', 'TRUE', "'1'", "'x'", "JSON '1'", "INTERVAL '-1' DAY", "CAST('NaN' AS DOUBLE)", 'DATE \'2000-01-01\''].each do |value|
  statements << "SELECT SIGN(#{value}) AS v;"
  statements << "SELECT SIGN(#{value}) AS v WHERE FALSE;"
end
samples.product(%w[SUM AVG], ['', ' WHERE FALSE']).each do |value, name, condition|
  input = value.nil? ? 'NULL' : "'#{value}'"
  statements << "SELECT #{name}(v) AS v FROM (VALUES (CAST(#{input} AS DOUBLE)),(CAST(1.25 AS DOUBLE)),(NULL)) t(v)#{condition};"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "DECFLOAT: #{statements.length} generated Java comparisons passed (finite/special arithmetic, mixed types, rounding, division, modulus, nulls, aggregates, inference and JSON)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "DecfloatOracle.java"))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    executions += 1
    result = statement.execute(*values)
    result.types.each_with_index do |type, index|
      precision = type.precision || {"INTEGER" => 32, "BIGINT" => 64, "BOOLEAN" => 1}.fetch(type.name)
      lines << "M\t#{result.columns[index]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      values = row.map do |value|
        if value.nil? then "null"
        elsif value.is_a?(BigDecimal) then H2::ArrayType.decimal_text(value, [value.scale, 0].max)
        else value.to_s
        end
      end
      lines << (["R"] + values).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  statement = connection.prepare("SELECT CAST('1e100' AS DECFLOAT(12)),CAST(? AS DECFLOAT(12)),CAST(1 AS DECFLOAT(2))/CAST(6 AS DECFLOAT(2)) AS d")
  ['1e100', nil].each { dump.call(statement, it) }
  pairs = [["1.25", "0.3"], ["1e100", "-3e-100"], ["-5", "2"], ["1", "0"], ["Infinity", "-Infinity"],
    ["NaN", "0"], [nil, "0"], ["bad", "1"], [H2::DecfloatValue.parse('9.999'), H2::DecfloatValue.parse('1')], ["1".b, "1"]]
  %w[+ - * / %].each do |operator|
    statement = connection.prepare("SELECT CAST(? AS DECFLOAT(5))#{operator}CAST(? AS DECFLOAT(3)) AS v")
    pairs.each { dump.call(statement, *it) }
  end
  statement = connection.prepare("SELECT ABS(CAST(? AS DECFLOAT(8))) AS a,SIGN(CAST(? AS DECFLOAT(8))) AS s")
  ["-1e100", "0", "Infinity", "-Infinity", "NaN", nil].each { dump.call(statement, it, it) }
  statement = connection.prepare("SELECT CAST(? AS DECFLOAT(5))+CAST(? AS NUMERIC(10,2)) AS a,MOD(CAST(? AS DECFLOAT(5)),CAST(? AS DECFLOAT(3))) AS m")
  dump.call(statement, "1.25", "2.50", "5.25", "2")
  dump.call(statement, nil, "2.50", "Infinity", "2")
  statement = connection.prepare("SELECT MOD(CAST(1.2 AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2))) AS c,MOD(CAST(? AS DECFLOAT(5)),CAST(2 AS NUMERIC(10,2))) AS p")
  ['1.2', '0'].each { dump.call(statement, it) }
  connection.execute("CREATE TABLE t(v DECFLOAT(5),g INT)")
  connection.execute("INSERT INTO t VALUES(1.25,1),(2.5,1),(1.25,2),(NULL,2)")
  statement = connection.prepare("SELECT SUM(v) AS s,AVG(v) AS a,SUM(DISTINCT v) AS d,AVG(v) FILTER(WHERE g>?) AS f FROM t")
  [1,nil].each { dump.call(statement, it) }
  connection.execute("INSERT INTO t VALUES('Infinity',2)")
  dump.call(statement, 1)
  statement = connection.prepare("SELECT SUM(v) AS s,MIN(v) AS lo,MAX(v) AS hi FROM t")
  dump.call(statement)
  connection.execute("INSERT INTO t VALUES('-Infinity',2)")
  dump.call(statement)
  connection.execute("CREATE TABLE source(v DECFLOAT(5))")
  connection.execute("INSERT INTO source VALUES(1.25),(2.5)")
  connection.execute("CREATE TABLE saved(v DECFLOAT(10) DEFAULT (SELECT SUM(v)+CAST(? AS DECFLOAT(3)) FROM source))", '1.25')
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  connection.execute("INSERT INTO source VALUES(1)")
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved"))
  connection.execute("CREATE TABLE doubles(v DOUBLE)")
  connection.execute("INSERT INTO doubles VALUES(1.25),(2.5),(NULL)")
  statement = connection.prepare("SELECT SUM(v) AS s,AVG(v) AS a FROM doubles")
  dump.call(statement)
  connection.execute("INSERT INTO doubles VALUES('Infinity')")
  dump.call(statement)
  dump.call(connection.prepare("SELECT SUM(v) AS s FROM doubles"))
  ["SELECT CAST('NaN' AS DECFLOAT)/0 WHERE FALSE", "SELECT MOD(CAST(1 AS DECFLOAT),0) WHERE FALSE"].each do |sql|
    begin
      connection.prepare(sql)
      lines << "P\tprepared"
    rescue H2::Error => error
      lines << "P\t#{error.code}\t#{error.sql_state}"
    end
  end
  lines.join("\n") + "\n"
end
abort "DECFLOAT JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "DECFLOAT: #{executions} JDBC executions and two preparation errors passed (reused bindings, precision, specials, arithmetic, aggregates and captured defaults)"

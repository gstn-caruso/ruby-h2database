# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

values = ['CAST(127 AS NUMERIC(3,0))', 'CAST(1.25 AS NUMERIC(8,2))', 'NULL', '0', '15', '-15', '2147483647', '9223372036854775807', '1.285', '-1.285', '9.995', '-9.995',
  'CAST(0.0000000001 AS NUMERIC(1,10))', 'CAST(1.285 AS NUMERIC(8,3))', 'CAST(127 AS TINYINT)',
  'CAST(32767 AS SMALLINT)', 'CAST(0.285 AS REAL)', 'CAST(0.285 AS DOUBLE)', 'CAST(-1.99 AS REAL)',
  "CAST('NaN' AS REAL)", "CAST('Infinity' AS DOUBLE)", "CAST('-Infinity' AS DOUBLE)",
  '1.285E0', '-9.995E0', '1E100', '1E-100', "CAST('NaN' AS DECFLOAT)", "CAST('Infinity' AS DECFLOAT)",
  "'1.25'", "'bad'", "'2000-02-29 12:34:56'", 'TRUE', "X'00000001'", 'ARRAY[1]', 'ROW(1,2)',
  "DATE '2000-02-29'", "TIMESTAMP '2000-02-29 12:34:56.123456789'", "TIMESTAMP WITH TIME ZONE '2000-02-29 12:34:56+03'",
  "TIME '12:34:56'", "INTERVAL '-1' DAY"]
scales = ['NULL', '-3', '-1', '0', '1', '2', '3', '1.5', "'1'", "'bad'", 'TRUE', 'CAST(-1.5 AS DOUBLE)', 'CAST(1.5 AS REAL)']
statements = []
values.product(%w[FLOOR CEIL CEILING ROUNDMAGIC ROUND TRUNC TRUNCATE]).each do |value, name|
  statements << "SELECT #{name}(#{value});"
  statements << "SELECT #{name}(v) AS v FROM (VALUES (#{value}),(#{value})) t(v);"
end
values.product(scales, %w[ROUND TRUNC]).each do |value, scale, name|
  statements << "SELECT #{name}(#{value},#{scale}) AS v;"
  statements << "SELECT #{name}(v,s) AS v FROM (VALUES (#{value},#{scale}),(#{value},#{scale})) t(v,s);"
end
%w[ROUND TRUNC].product(['NULL','1','1.25','1E-100'], ['100000','-100000','100001','-100001','2147483648',"CAST('NaN' AS DOUBLE)","CAST('NaN' AS DECFLOAT)"]).each do |name, value, scale|
  statements << "SELECT #{name}(#{value},#{scale}) AS v;"
  statements << "SELECT #{name}(#{value},#{scale}) AS v WHERE FALSE;"
end
['0.30000000000000004', '0.009999999999999787', '0.00000000000001', '-0.00000000000001',
  '999999999999.9999', '1000000000000.0001', '1.9999999999999998', '-1.9999999999999998', '1.0000000000000002', '2.0000000000000004',
  'NaN', 'Infinity', '-Infinity'].each do |value|
  statements << "SELECT ROUNDMAGIC(CAST('#{value}' AS DOUBLE));"
end
%w[ROUND FLOOR CEIL CEILING TRUNC TRUNCATE ROUNDMAGIC].each do |name|
  ['', '1,2,3', 'DISTINCT 1'].each { statements << "SELECT #{name}(#{it});" }
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Numeric rounding: #{statements.length} generated Java comparisons passed (rounding modes, aliases, types, dynamic scales, nulls, errors, bounds, temporal TRUNC and ROUNDMAGIC)"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "NumericRoundingOracle.java"))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    executions += 1
    result = statement.execute(*values)
    result.types.each_with_index do |type, i|
      precision = type.precision || {"REAL" => 24, "DOUBLE" => 53, "TINYINT" => 8, "SMALLINT" => 16, "INTEGER" => 32, "BIGINT" => 64}.fetch(type.name)
      lines << "M\t#{result.columns[i]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      values = row.each_with_index.map do |value, i|
        if value.nil? then 'null'
        elsif value.is_a?(Float) then H2::JsonValue.float_text(value, real: result.types[i].name == 'REAL')
        elsif value.is_a?(BigDecimal) then H2::ArrayType.decimal_text(value,result.types[i].scale)
        else value.to_s
        end
      end
      lines << (["R"] + values).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  pairs = [["1.255",2],["-1.255",1],[nil,0],["1.25",nil],["1.25",4],["127",-1],["1.25","bad"],[nil,"bad"],["1.25",100001],["1.25",Float::NAN],["1.25",-Float::INFINITY]]
  ['NUMERIC(8,3)','DECFLOAT(8)','REAL','DOUBLE','TINYINT','BIGINT'].product(%w[ROUND TRUNC]).each do |type, name|
    statement = connection.prepare("SELECT #{name}(CAST(? AS #{type}),?) AS v")
    pairs.each { dump.call(statement,*it) }
  end
  statement = connection.prepare("SELECT ROUND(CAST(? AS NUMERIC(8,3)),NULL) AS n,TRUNC(CAST(? AS DECFLOAT(8)),NULL) AS d")
  dump.call(statement,'1.25','1.25')
  dump.call(statement,nil,nil)
  statement = connection.prepare("SELECT TRUNC(CAST(? AS DATE)) AS d,TRUNC(CAST(? AS TIMESTAMP(3))) AS t,TRUNC(CAST(? AS VARCHAR)) AS s")
  dump.call(statement,'2000-02-29','2000-02-29 12:34:56.789','2000-02-29 12:34:56')
  dump.call(statement,nil,nil,nil)
  dump.call(statement,'bad','bad','bad')
  statement = connection.prepare("SELECT FLOOR(CAST(? AS REAL)) AS r,CEIL(CAST(? AS DOUBLE)) AS d,ROUNDMAGIC(?) AS m")
  dump.call(statement,'NaN','Infinity','0.30000000000000004')
  dump.call(statement,'-Infinity','NaN','0.00000000000001')
  dump.call(statement,nil,nil,nil)
  connection.execute("CREATE TABLE t(n NUMERIC(10,2),s INT)")
  connection.execute("INSERT INTO t VALUES(99999999.99,1)")
  dump.call(connection.prepare("SELECT ROUND(n,-1) AS a,ROUND(n,1) AS b,ROUND(n,2) AS c,ROUND(n,s) AS d,TRUNC(n,-1) AS e FROM t"))
  connection.execute("CREATE TABLE source(n NUMERIC(8,3),s INT)")
  connection.execute("INSERT INTO source VALUES(1.255,2)")
  connection.execute("CREATE TABLE saved(n NUMERIC(9,3) DEFAULT (SELECT ROUND(n,s) FROM source),p NUMERIC(9,3) DEFAULT ROUND((SELECT n FROM source),?))",1)
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  connection.execute("UPDATE source SET n=-1.255,s=1")
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved ORDER BY n"))
  ["SELECT ROUND(NULL,'bad') WHERE FALSE","SELECT ROUND(1,100001) WHERE FALSE","SELECT FLOOR('1') WHERE FALSE","SELECT TRUNC(DATE '2000-01-01',0) WHERE FALSE","SELECT ROUND(?)"].each do |sql|
    begin
      connection.prepare(sql)
      lines << "P\tprepared"
    rescue H2::Error => error
      lines << "P\t#{error.code}\t#{error.sql_state}"
    end
  end
  lines.join("\n") + "\n"
end
abort "Numeric rounding JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Numeric rounding: #{executions} JDBC executions and five preparation checks passed (reused scales, null ordering, metadata, float widths, specials, temporal TRUNC and captured defaults)"

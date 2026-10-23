# frozen_string_literal: true

require "open3"

quote = ->(text) { "'" + text.gsub("'", "''") + "'" }
samples = ['', ' ', 'null', 'true', 'false', 'NULL', '1', '001', '-01', '1.00', '-0.00', '1e100', '1.2300e-9', '0e-999',
  '+1', '1.', '.1', '1e', '1e+', 'NaN', 'Infinity', 'true false', '[]', '{}', '[1,null,"x"]', '[1,]', '[,1]', '{"a":1}',
  '{"a":1,"a":2}', '{"x":[{"a":1,"a":2}]}', '{"a":}', '{"a" 1}', '{"a":1,}', '{1:2}', '{"a":1}[]', '""', '"a\\\\b"',
  '"\/"', '"\u00e9"', '"\ud83d\ude00"', '"\ud800"', '"\udc00"', '"\ud800x"', '"\u+001"', '"\u-001"', '"\uZZZZ"',
  "\"line\nbreak\"", "\"raw\u0001control\"", '"😀é§''"', "\uFEFF[1]", " \uFEFF[1]", "\u00a0[1]"]
statements = []
samples.concat(['"\u０００１"', '"\u٠٠٠١"', '"\uＦＦＦＦ"'])
samples.concat(['1e2147483647', '1e2147483648', '1e-2147483647', '1e-2147483648'])
samples.each do |text|
  expressions = []
  expressions << quote.call(text) unless text.match?(/[\x00-\x1f]/)
  %w[UTF-8 UTF-16BE UTF-16LE UTF-32BE UTF-32LE].each do |encoding|
    expressions << "X'#{text.encode(encoding).b.unpack1('H*')}'"
  end
  expressions.each do |expression|
    statements << "SELECT #{expression} FORMAT JSON AS j;"
    statements << "SELECT CAST(#{expression} AS JSON) AS j;"
    %w[VALUE ARRAY OBJECT SCALAR].product(['', ' WITH UNIQUE KEYS'], ['', ' NOT']).each do |item, unique, negate|
      statements << "SELECT #{expression} IS#{negate} JSON #{item}#{unique} AS v;"
    end
  end
end
values = ['NULL', 'TRUE', 'FALSE', '1', '-1', '1.250', '1e100', '-1e-9', 'CAST(1.2 AS REAL)', 'CAST(1e7 AS DOUBLE)',
  'CAST(1e-4 AS DOUBLE)', "'x'", "'null'", "X'31'", "X'ff'", "DATE '2000-02-29'", "TIME '12:34:56.123456789'",
  "TIMESTAMP '2000-01-01 12:34:56.123456789'", "TIMESTAMP WITH TIME ZONE '2000-01-01 12:34:56+03'",
  "UUID '01234567-89ab-cdef-0123-456789abcdef'", "INTERVAL '1' DAY", 'ROW(1,2)', 'ARRAY[1,NULL,2]', "JSON 'null'", "JSON '{\"a\":1}'"]
values << '1.2300e-9'
values.product(['', '(1)', '(3)', '(20)']).each do |value, precision|
  statements << "SELECT CAST(#{value} AS JSON#{precision}) AS j;"
end
values.product(['', ' NULL ON NULL', ' ABSENT ON NULL']).each do |value, flags|
  statements << "SELECT JSON_ARRAY(#{value}#{flags}) AS j;"
  statements << "SELECT JSON_OBJECT('k':#{value}#{flags}) AS j;"
  statements << "SELECT JSON_OBJECT(#{value}:1.250#{flags}) AS j;"
end
jsons = ["JSON '1'", "JSON '1.0'", "JSON 'null'", "JSON '\"x\"'", "JSON '{\"a\":1}'", "JSON '[1,null]'", 'NULL']
targets = ['VARCHAR', 'VARCHAR(3)', 'CHAR(2)', 'VARBINARY', 'VARBINARY(3)', 'BINARY(2)', 'INT', 'NUMERIC', 'BOOLEAN', 'UUID', 'DATE', 'TIME', 'INTERVAL DAY']
jsons.product(targets).each { |json, type| statements << "SELECT CAST(#{json} AS #{type}) AS v;" }
jsons.product(jsons + ["'1'", "'x'", "X'31'", '1', 'TRUE'], %w[= <> < > <= >=]).each do |a, b, operator|
  statements << "SELECT #{a}#{operator}#{b} AS v;"
end
['NULL', "JSON 'null'", "JSON '1'", "JSON '[]'", "JSON '[null,\"x\",{\"a\":1}]'", "'[1,2]' FORMAT JSON", 'JSON_ARRAY(1,2)', "CAST('[1,2]' FORMAT JSON AS JSON)"].each do |input|
  statements << "SELECT * FROM UNNEST(#{input}) WITH ORDINALITY;"
  ['NULL', '-1', '0', '1', '2', '3', '2147483648', "'bad'", '1.5'].each do |index|
    statements << "SELECT #{input}[#{index}] AS j;"
  end
end
values.product(['', ' NULL ON NULL', ' ABSENT ON NULL'], ['', ' WITH UNIQUE KEYS']).each do |value, nulls, unique|
  statements << "SELECT JSON_OBJECT('a':#{value},'a':NULL#{nulls}#{unique}) AS j;"
end
%w[2282a022 22eda0bdedb88022 22eda08022 22edb08022 22c08022 22f490808022 efbbbf31 22eda0bd5c756465303022].each do |hex|
  statements << "SELECT X'#{hex}' FORMAT JSON AS j;"
  statements << "SELECT X'#{hex}' IS JSON AS v;"
end
['SELECT 1', 'VALUES 1,2', "VALUES '1','{}',NULL", 'SELECT 1,2'].product(['', ' FORMAT JSON'], ['', ' NULL ON NULL']).each do |query, format, flags|
  statements << "SELECT JSON_ARRAY((#{query})#{format}#{flags}) AS j;"
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "JSON: #{statements.length} generated Java comparisons passed (normalization, UTF encodings, numbers, duplicates, shapes, conversions, constructors, comparisons, bounds and UNNEST)"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "JsonOracle.java"))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    executions += 1
    result = statement.execute(*values)
    result.types.each_with_index do |type, i|
      precision = type.precision || {"BOOLEAN" => 1}.fetch(type.name)
      name = {"VARCHAR" => "CHARACTER VARYING", "CHAR" => "CHARACTER"}.fetch(type.name, type.name)
      lines << "M\t#{result.columns[i]}\t#{name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      values = row.each_with_index.map do |value, index|
        if value.nil? then 'null'
        elsif %w[VARCHAR CHAR].include?(result.types[index].name) then 'S' + H2::CharacterString.sort_key(value).unpack1('H*')
        elsif [true, false].include?(value) then value.to_s.upcase
        else value.to_s
        end
      end
      lines << (["R"] + values).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  statement = connection.prepare("SELECT CAST(? AS JSON) AS casted,? FORMAT JSON AS parsed,? IS JSON WITH UNIQUE KEYS AS valid,(? FORMAT JSON)[?] AS item,? IS OF(JSON) AS istype")
  [["x", "[1,null]", '{"a":1,"a":2}', "[1,null]", 2, H2::JsonValue.parse('null')],
    ["[2]".encode('UTF-16LE').b, "{}".encode('UTF-32BE').b, "[]".b, nil, 1, nil],
    [nil, nil, nil, nil, nil, "null"], ["null", "bad", "{}", "[]", 1, H2::JsonValue.parse('null')],
    ["null".b, "1.00", 1, "[]", -1, H2::JsonValue.parse('1')]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT JSON_OBJECT(?:?,?:? ABSENT ON NULL WITH UNIQUE KEYS) AS o,JSON_ARRAY(?,? NULL ON NULL) AS a")
  [["a", 1, "a", nil, nil, H2::JsonValue.parse('null')], ["a", 1, "a", 2, 1, 2], [nil, 1, "a", 2, 1, 2],
    ["a", H2::JsonValue.parse('null'), "b", "x", H2::JsonValue.parse('[]'), "x"]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT CAST(? AS JSON(4)) AS j")
  ["null".b, "true".b, "é", "😀", [0xd800].pack('n*').force_encoding(Encoding::UTF_16BE), nil, "\xff".b].each { dump.call(statement, it) }
  statement = connection.prepare("SELECT CAST(CAST(? AS JSON) AS VARCHAR(3)) AS v,CAST(CAST(? AS JSON) AS CHAR(2)) AS c")
  [['"😀"'.b, '"😀"'.b], ["{}".b, "{}".b], [nil, nil]].each { dump.call(statement, *it) }
  statement = connection.prepare("SELECT CAST(? AS JSON) AS j,CAST(? AS DECFLOAT(3)) AS d")
  dump.call(statement, H2::DecfloatValue.parse('1.2300e100'), H2::DecfloatValue.parse('9.999'))
  dump.call(statement, H2::DecfloatValue.parse('Infinity'), H2::DecfloatValue.parse('0'))
  dump.call(statement, nil, nil)
  connection.execute("CREATE TABLE source(v INT)")
  connection.execute("INSERT INTO source VALUES(1),(2)")
  connection.execute("CREATE TABLE saved(j JSON DEFAULT JSON_ARRAY(SELECT v FROM source WHERE v>? ORDER BY v))", 1)
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  connection.execute("INSERT INTO source VALUES(3)")
  connection.execute("INSERT INTO saved DEFAULT VALUES")
  dump.call(connection.prepare("TABLE saved"))
  lines.join("\n") + "\n"
end
abort "JSON JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "JSON: #{executions} JDBC executions passed (reused typed/text/binary/null parameters, encodings, constructors, precision, UTF-16 casts, errors, metadata and captured query defaults)"

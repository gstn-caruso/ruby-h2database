# frozen_string_literal: true

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first" unless File.file?(jar)
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
oracle = [java, "-cp", jar, File.join(__dir__, "JdbcOracle.java")]
decode = ->(value) { value.unpack1("m0").force_encoding(Encoding::UTF_8) }
type_name = ->(name) { name.start_with?("ROW(") && !name.end_with?(" ARRAY") ? "ROW" : {"CHARACTER VARYING" => "VARCHAR", "CHARACTER" => "CHAR", "DOUBLE PRECISION" => "DOUBLE", "BINARY VARYING" => "VARBINARY"}.fetch(name, name) }
normalize = lambda do |value, type|
  next nil if value.nil?

  if %w[BINARY VARBINARY].include?(type)
    value.unpack1("H*")
  elsif %w[TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE].include?(type)
    BigDecimal(value.to_s).to_s("F")
  elsif [true, false].include?(value)
    value ? "TRUE" : "FALSE"
  else
    value.to_s
  end
end
java_run = lambda do |path, statements, password = ""|
  input = statements.map { [it].pack("m0") }.join("\n") + "\n"
  output, error, status = Open3.capture3(*oracle, "jdbc:h2:#{path}", "sa", password, stdin_data: input)
  abort error unless status.success?
  output.split("END\n").map do |result|
    lines = result.lines.map(&:chomp)
    kind, *values = lines.first.split("\t")
    case kind
    when "U" then {update: values.first.to_i}
    when "E" then {error: values.first.to_i, state: values.last}
    when "Q"
      names = values.map { decode.call(it) }
      types = lines[1].split("\t").drop(1).map { type_name.call(decode.call(it)) }
      rows = lines.drop(2).map do |line|
        line.split("\t").drop(1).each_with_index.map { |value, index| normalize.call(value == "N" ? nil : decode.call(value[1..]), types[index]) }
      end
      {columns: names, types: types, rows: rows}
    else abort "Unexpected JDBC result #{result}"
    end
  end
end
ruby_run = lambda do |path, statements, **options|
  H2.connect(path: path, **options) do |connection|
    statements.map do |sql|
      begin
        result = connection.execute(sql)
        if result.query?
          types = result.types.map { type_name.call(it.name) }
          {columns: result.columns, types: types, rows: result.rows.map { |row| row.each_with_index.map { |value, index| normalize.call(value, types[index]) } }}
        else
          {update: result.update_count}
        end
      rescue H2::Error => error
        {error: error.code, state: error.sql_state}
      end
    end
  end
end
checks = 0
assert = lambda do |condition, message|
  abort message unless condition
  checks += 1
end
compare = lambda do |expected, actual, label|
  assert.call(expected.length == actual.length, "#{label}: statement count differs")
  expected.zip(actual).each_with_index { |(a, b), index| assert.call(a == b, "#{label} statement #{index + 1}:\nJava: #{a.inspect}\nRuby: #{b.inspect}") }
end
schema = [
  "CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(50) UNIQUE, amount NUMERIC(12,3) DEFAULT 1.250, active BOOLEAN)",
  "INSERT INTO people VALUES(-7,'Ada 😀',12.375,TRUE),(0,NULL,0,FALSE),(9,'Grace',99.125,NULL)",
  "CREATE TABLE pairs(a VARCHAR, b BIGINT, v CHAR(4), PRIMARY KEY(a,b))",
  "INSERT INTO pairs VALUES('a',1,'x'),('a',2,'y')",
  "CREATE TABLE bag(a INT,b VARCHAR)",
  "INSERT INTO bag VALUES(1,'same'),(1,'same'),(NULL,NULL)",
  "CREATE TABLE typed(t TINYINT,s SMALLINT,b BIGINT,r REAL,d DOUBLE,c CHAR(3),v VARCHAR)",
  "INSERT INTO typed VALUES(-128,-32768,-9223372036854775808,1.25,-3.5,'x','café 中文')",
  "CREATE TABLE source(v INT)", "INSERT INTO source VALUES(10)",
  "CREATE TABLE target(v INT DEFAULT (SELECT MAX(v)+7 FROM source))", "INSERT INTO target DEFAULT VALUES",
  "CREATE TABLE rows_table AS SELECT ROW(1,'nested',ROW(TRUE,NULL)) AS pair",
  'CREATE TABLE "odd""table"("a""b" VARCHAR DEFAULT \'O\'\'Brien 😀\')',
  'INSERT INTO "odd""table" DEFAULT VALUES',
  "CREATE TABLE bytes(u UUID PRIMARY KEY, b BINARY(4) DEFAULT X'00ff', v VARBINARY(20) UNIQUE)",
  "INSERT INTO bytes(u,v) VALUES('01234567-89ab-cdef-0123-456789abcdef',X'00ffeda080'),('ffffffff-ffff-ffff-ffff-ffffffffffff',X''),('00000000-0000-0000-0000-000000000000',NULL)",
  "CREATE TABLE binary_defaults(u UUID DEFAULT UUID 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', b VARBINARY DEFAULT X'ff00', small VARBINARY DEFAULT CAST(-1 AS SMALLINT))",
  "INSERT INTO binary_defaults DEFAULT VALUES",
  "CREATE TABLE empty_binary(v VARBINARY) AS SELECT X''",
  "CREATE TABLE binary_rows AS SELECT ROW(UUID '01234567-89ab-cdef-0123-456789abcdef',X'ff00') AS pair",
  "CREATE TABLE set_rows AS SELECT id FROM people UNION SELECT a FROM bag INTERSECT VALUES 1,2",
  "CREATE TABLE set_default(v INT DEFAULT (SELECT v FROM source UNION ALL SELECT 5 ORDER BY (1) LIMIT 1))",
  "INSERT INTO set_default DEFAULT VALUES",
  "CREATE TABLE cte_rows AS WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<3) TABLE r",
  "CREATE TABLE cte_default(v INT DEFAULT (WITH RECURSIVE r(n) AS (VALUES 1 UNION ALL SELECT n+1 FROM r WHERE n<(SELECT MAX(v) FROM source)) SELECT MAX(n) FROM r))",
  "INSERT INTO cte_default DEFAULT VALUES",
  "CREATE TABLE temporal(d DATE PRIMARY KEY,t TIME(9) UNIQUE,ts TIMESTAMP(9))",
  "INSERT INTO temporal VALUES(DATE '-1000000000-01-01',TIME '00:00:00.000000001',TIMESTAMP '-1000000000-01-01 12:34:56.123456789'),(DATE '0000-02-29',TIME '12:34:56.123456789',TIMESTAMP '0000-02-29 23:59:59.999999999'),(DATE '1000000000-12-31',TIME '23:59:59.999999999',TIMESTAMP '1000000000-12-31 23:59:59.999999999')",
  "CREATE TABLE temporal_defaults(d DATE DEFAULT DATE '2000-02-29',t TIME(9) DEFAULT TIME '12:34:56.123456789',ts TIMESTAMP(9) DEFAULT TIMESTAMP '2000-02-29 12:34:56.123456789',y INT DEFAULT EXTRACT(YEAR FROM (SELECT MAX(d) FROM temporal)))",
  "INSERT INTO temporal_defaults DEFAULT VALUES",
  "CREATE TABLE temporal_rows AS SELECT ROW(DATE '2000-01-01',TIME '12:34:56.123456789',TIMESTAMP '2000-01-01 00:00:00.123456789') AS pair",
  "CREATE TABLE calendar(d DATE PRIMARY KEY,t TIME(9),ts TIMESTAMP(9))",
  "INSERT INTO calendar VALUES(DATE '2000-01-31',TIME '23:59:59.999999999',TIMESTAMP '2000-01-31 23:59:59.999999999')",
  "CREATE TABLE calendar_default(d DATE DEFAULT TIMESTAMPADD(month,1,(SELECT MAX(d) FROM calendar)),n BIGINT DEFAULT TIMESTAMPDIFF(day,DATE '2000-01-01',(SELECT MAX(d) FROM calendar)))",
  "INSERT INTO calendar_default DEFAULT VALUES",
  "CREATE TABLE calendar_shift AS SELECT DATEADD(ns,1,ts) AS ts,DATEDIFF(month,DATE '1999-12-31',d) AS n FROM calendar",
  "CREATE TABLE periods(lo DATE DEFAULT DATE_TRUNC(month,(SELECT MAX(d) FROM calendar)),hi DATE DEFAULT LAST_DAY((SELECT MAX(d) FROM calendar)),iso INT DEFAULT EXTRACT(iso_week FROM (SELECT MAX(d) FROM calendar)),epoch NUMERIC(28,9) DEFAULT EXTRACT(epoch FROM (SELECT MAX(d) FROM calendar)))",
  "INSERT INTO periods DEFAULT VALUES",
  "CREATE TABLE trunc_copy AS SELECT DATE_TRUNC(month,d) AS d,DATE_TRUNC(mcs,t) AS t,DATE_TRUNC(iso_week_year,ts) AS ts,EXTRACT(epoch FROM ts) AS epoch,LAST_DAY(d) AS last_day FROM calendar",
  "CREATE TABLE session_defaults(d DATE DEFAULT CURRENT_DATE,t TIME(9) DEFAULT LOCALTIME(9),ts TIMESTAMP(9) DEFAULT LOCALTIMESTAMP(9),promoted TIMESTAMP DEFAULT CAST(TIME '12:00:00' AS TIMESTAMP),m INTERVAL MONTH(5) DEFAULT (CURRENT_DATE-TIME '12:00:00') MONTH,implicit TIMESTAMP DEFAULT COALESCE(TIME '12:00:00',TIMESTAMP '1900-01-01 00:00:00'),equal BOOLEAN DEFAULT TIME '12:00:00'=TIMESTAMP '2000-02-29 12:00:00')",
  "INSERT INTO session_defaults DEFAULT VALUES",
  "CREATE TABLE zoned_values(id INT PRIMARY KEY,t TIME(9) WITH TIME ZONE UNIQUE,ts TIMESTAMP(9) WITH TIME ZONE UNIQUE,local_value TIMESTAMP DEFAULT CAST(TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00Z' AS TIMESTAMP))",
  "INSERT INTO zoned_values(id,t,ts) VALUES(1,TIME WITH TIME ZONE '00:00:00+18',TIMESTAMP WITH TIME ZONE '-1000000000-01-01 00:00:00-18'),(2,TIME WITH TIME ZONE '12:34:56.123456789+03:30:15',TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00+03'),(3,TIME WITH TIME ZONE '23:59:59.999999999-18',TIMESTAMP WITH TIME ZONE '1000000000-12-31 23:59:59.999999999+18'),(4,NULL,NULL)",
  "CREATE TABLE zoned_clock(c TIMESTAMP(9) WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP(9),t TIME(9) WITH TIME ZONE DEFAULT CURRENT_TIME(9),l TIMESTAMP(9) DEFAULT LOCALTIMESTAMP(9))",
  "INSERT INTO zoned_clock DEFAULT VALUES"
]
queries = ["TABLE people ORDER BY id", "TABLE pairs ORDER BY a,b", "TABLE bag ORDER BY a NULLS LAST,b NULLS LAST",
  "TABLE typed", "TABLE target", "TABLE rows_table", 'TABLE "odd""table"', "SELECT id FROM people WHERE name='Ada 😀'",
  "TABLE bytes ORDER BY u", "TABLE binary_defaults", "SELECT u FROM bytes WHERE v=X'00ffeda080'",
  "TABLE empty_binary", "TABLE binary_rows", "TABLE set_rows ORDER BY id", "TABLE set_default ORDER BY v",
  "SELECT id FROM set_rows INTERSECT SELECT id FROM people ORDER BY id",
  "TABLE cte_rows ORDER BY n", "TABLE cte_default ORDER BY v",
  "WITH q(n) AS (TABLE cte_rows) SELECT n FROM q WHERE n IN(WITH r(n) AS (VALUES 1,3) TABLE r) ORDER BY n",
  "TABLE temporal ORDER BY d", "TABLE temporal_defaults ORDER BY y", "TABLE temporal_rows",
  "SELECT d FROM temporal WHERE t=TIME '12:34:56.123456789'",
  "TABLE calendar ORDER BY d", "TABLE calendar_default ORDER BY d", "TABLE calendar_shift",
  "SELECT DATEADD(month,1,d) AS d,DATEADD(ns,1,t) AS t,DATEDIFF(second,ts,DATEADD(month,1,ts)) AS n FROM calendar ORDER BY d",
  "TABLE periods ORDER BY lo", "TABLE trunc_copy ORDER BY d",
  "SELECT EXTRACT(iso_week_year FROM d) AS y,EXTRACT(iso_week FROM d) AS w,DATE_TRUNC(week_year,ts) AS ts FROM calendar ORDER BY d",
  "SELECT d=CAST(ts AS DATE) AS d,t=CAST(ts AS TIME(9)) AS t,promoted=CAST(d AS TIMESTAMP)+TIME '12:00:00' AS p,m=INTERVAL '-1' MONTH AS m,implicit=promoted AS i,equal=(d=DATE '2000-02-29') AS e FROM session_defaults ORDER BY ts",
  "TABLE zoned_values ORDER BY id", "SELECT id FROM zoned_values WHERE ts=TIMESTAMP WITH TIME ZONE '2000-01-01 09:00:00Z'",
  "SELECT CAST(c AS TIME(9) WITH TIME ZONE)=t AS t,CAST(c AS TIMESTAMP(9))=l AS l FROM zoned_clock ORDER BY c"]
changes = ["UPDATE people SET amount=amount+1 WHERE id=-7", "INSERT INTO people(id,name) VALUES(20,'new')",
  "DELETE FROM bag WHERE a IS NULL", "UPDATE bag SET b='updated' WHERE a=1", "INSERT INTO bag VALUES(2,'later')",
  "UPDATE source SET v=20", "INSERT INTO target DEFAULT VALUES", "INSERT INTO pairs VALUES('b',3,'z')",
  "INSERT INTO people VALUES(9,'duplicate',0,TRUE)", "INSERT INTO pairs VALUES('a',1,'dup')",
  "UPDATE bytes SET b=X'ff',v=X'80ff00' WHERE u='0123456789abcdef0123456789abcdef'",
  "DELETE FROM bytes WHERE u=UUID 'ffffffff-ffff-ffff-ffff-ffffffffffff'",
  "INSERT INTO bytes(u,v) VALUES('11111111-1111-1111-1111-111111111111',X'00')",
  "INSERT INTO bytes(u,v) VALUES('22222222-2222-2222-2222-222222222222',X'80ff00')",
  "INSERT INTO binary_defaults DEFAULT VALUES", "INSERT INTO set_default DEFAULT VALUES",
  "INSERT INTO set_rows SELECT id FROM people EXCEPT VALUES 0", "INSERT INTO cte_default DEFAULT VALUES",
  "INSERT INTO cte_rows WITH q(n) AS (VALUES 4) TABLE q",
  "UPDATE temporal SET d=d+1,ts=ts+1 WHERE d=DATE '0000-02-29'",
  "DELETE FROM temporal WHERE d=DATE '1000000000-12-31'",
  "INSERT INTO temporal VALUES(DATE '2000-02-29',TIME '10:00:00.000000002',TIMESTAMP '2000-02-29 00:00:00.000000002')",
  "INSERT INTO temporal VALUES(DATE '2000-02-29',NULL,NULL)",
  "INSERT INTO temporal VALUES(DATE '2000-03-01',TIME '10:00:00.000000002',NULL)",
  "INSERT INTO temporal_defaults DEFAULT VALUES",
  "UPDATE calendar SET d=DATEADD(month,1,d),t=DATEADD(ns,1,t),ts=DATEADD(ns,1,ts)",
  "INSERT INTO calendar_default DEFAULT VALUES",
  "INSERT INTO calendar_shift SELECT DATEADD(month,1,ts),DATEDIFF(day,DATE '2000-01-01',d) FROM calendar",
  "INSERT INTO periods DEFAULT VALUES",
  "INSERT INTO trunc_copy SELECT DATE_TRUNC(month,d),DATE_TRUNC(mcs,t),DATE_TRUNC(iso_week_year,ts),EXTRACT(epoch FROM ts),LAST_DAY(d) FROM calendar",
  "INSERT INTO session_defaults DEFAULT VALUES",
  "UPDATE zoned_values SET ts=ts+INTERVAL '0.000000001' SECOND,t=DATEADD(ns,1,t) WHERE id=2",
  "INSERT INTO zoned_values(id,ts) VALUES(5,TIMESTAMP WITH TIME ZONE '2000-01-01 09:00:00.000000001Z')",
  "UPDATE zoned_values SET t=t AT TIME ZONE 'UTC' WHERE id=2",
  "UPDATE zoned_values SET ts=ts AT TIME ZONE '-05' WHERE id=3",
  "INSERT INTO zoned_clock DEFAULT VALUES"]

schema.concat([
  "CREATE TABLE arrays(a INT ARRAY PRIMARY KEY,n TIMESTAMP(9) WITH TIME ZONE ARRAY[3] ARRAY[2],b VARBINARY(4) ARRAY,d NUMERIC(8,3) ARRAY,u UUID ARRAY)",
  "INSERT INTO arrays VALUES(ARRAY[],ARRAY[ARRAY[TIMESTAMP WITH TIME ZONE '2000-01-01 12:34:56.123456789+03']],ARRAY[X'00',NULL,X'ff'],ARRAY[1.250,NULL,2.500],ARRAY[UUID '01234567-89ab-cdef-0123-456789abcdef']),(ARRAY[1],NULL,NULL,NULL,NULL),(ARRAY[1,2],NULL,NULL,NULL,NULL),(ARRAY[1,2,3],NULL,NULL,NULL,NULL),(ARRAY[2],NULL,NULL,NULL,NULL),(ARRAY[NULL],NULL,NULL,NULL,NULL)",
  "CREATE TABLE array_defaults(a INT ARRAY DEFAULT ARRAY(SELECT v FROM source ORDER BY v),n NUMERIC(5,3) ARRAY DEFAULT ARRAY[1.250,2.500],b VARBINARY ARRAY DEFAULT ARRAY[CAST(1 AS SMALLINT)],d NUMERIC(12,2) ARRAY DEFAULT TRIM_ARRAY(ARRAY[CAST((SELECT v FROM source) AS INT),2.00],1))",
  "INSERT INTO array_defaults DEFAULT VALUES",
  "CREATE TABLE array_rows AS SELECT ARRAY[ROW(1,'x'),ROW(2,'abc')] AS a",
  "CREATE TABLE empty_arrays AS SELECT ARRAY(SELECT v FROM source WHERE FALSE) AS a"
])
queries.concat(["TABLE arrays ORDER BY a", "TABLE array_defaults ORDER BY a", "TABLE array_rows", "TABLE empty_arrays",
  "SELECT a,CARDINALITY(a) AS c,ARRAY_MAX_CARDINALITY(a) AS m FROM arrays ORDER BY a"])
changes.concat(["UPDATE arrays SET b=ARRAY[X'ffff'],d=d||3.750 WHERE a=ARRAY[]", "INSERT INTO arrays(a) VALUES(ARRAY[1,2])",
  "DELETE FROM arrays WHERE a=ARRAY[1,2,3]", "INSERT INTO array_defaults DEFAULT VALUES", "INSERT INTO empty_arrays VALUES(ARRAY[1,2])"])

schema.concat([
  "CREATE TABLE array_aggregates AS SELECT ARRAY_AGG(a ORDER BY a) AS a,COUNT(*) FILTER(WHERE CARDINALITY(a)>0) AS n FROM arrays",
  "CREATE TABLE array_aggregate_defaults(a INT ARRAY DEFAULT (SELECT ARRAY_AGG(v ORDER BY v DESC) FILTER(WHERE v>0) FROM source),u INT ARRAY DEFAULT (SELECT ARRAY_AGG(c1 ORDER BY c1) FROM UNNEST(COALESCE(ARRAY[1,2],NULL))))",
  "INSERT INTO array_aggregate_defaults DEFAULT VALUES",
  "CREATE TABLE unnested AS SELECT * FROM UNNEST(ARRAY[1,2],ARRAY['a']) WITH ORDINALITY",
  "CREATE TABLE unnest_unknown AS SELECT * FROM UNNEST(1)"
])
queries.concat(["TABLE array_aggregates ORDER BY n", "TABLE array_aggregate_defaults ORDER BY a", "TABLE unnested ORDER BY nord", "TABLE unnest_unknown"])
changes.concat(["INSERT INTO array_aggregate_defaults DEFAULT VALUES", "INSERT INTO array_aggregates SELECT ARRAY_AGG(a ORDER BY a),COUNT(*) FILTER(WHERE CARDINALITY(a)>0) FROM arrays"])

schema.concat([
  "CREATE TABLE quantified_defaults(a BOOLEAN DEFAULT 2=ANY(ARRAY[1,2,NULL]),q BOOLEAN DEFAULT 10>ALL(SELECT v FROM source),c INT DEFAULT CASE 1 WHEN =ANY(ARRAY[1,2]) THEN 1 ELSE 2 END)",
  "INSERT INTO quantified_defaults DEFAULT VALUES",
  "CREATE TABLE quantified_rows AS SELECT a,a=ANY(SELECT a FROM arrays) AS present,a IS DISTINCT FROM ALL(ARRAY[ARRAY[1]]) AS different FROM arrays"
])
queries.concat(["TABLE quantified_defaults ORDER BY q", "TABLE quantified_rows ORDER BY a"])
changes.concat(["INSERT INTO quantified_defaults DEFAULT VALUES", "UPDATE quantified_rows SET different=a=ANY(ARRAY[ARRAY[2]])"])

schema.concat([
  "CREATE TABLE json_values(j JSON(100) PRIMARY KEY,a JSON ARRAY,d JSON DEFAULT JSON_OBJECT('n':(SELECT v FROM source),'duplicate':JSON '{\"a\":1,\"a\":2}'))",
  "INSERT INTO json_values(j,a) VALUES(JSON 'null',ARRAY[JSON '1',JSON 'null',NULL]),(JSON '{\"a\":1,\"a\":2}',ARRAY[JSON '[]',JSON '{}']),(JSON '\"😀\"',NULL)",
  "CREATE TABLE json_queries(j JSON DEFAULT JSON_ARRAY(SELECT v FROM source ORDER BY v DESC),p BOOLEAN DEFAULT (SELECT CAST(v AS JSON) FROM source) IS JSON SCALAR WITH UNIQUE KEYS,n JSON DEFAULT JSON_OBJECT('n':1e100,'source':(SELECT v FROM source)))",
  "INSERT INTO json_queries DEFAULT VALUES",
  "CREATE TABLE json_ctas AS SELECT JSON_OBJECT('a':a,'n':n) AS j FROM arrays"
])
queries.concat(["TABLE json_values ORDER BY j", "TABLE json_queries ORDER BY j", "TABLE json_ctas ORDER BY j"])
changes.concat(["INSERT INTO json_values(j) VALUES(JSON '[1,2]')", "UPDATE json_values SET a=ARRAY[JSON 'true',JSON '{\"x\":[1,null]}'] WHERE j=JSON 'null'",
  "INSERT INTO json_queries DEFAULT VALUES", "INSERT INTO json_ctas SELECT JSON_ARRAY(a) FROM arrays"])
schema.concat(["CREATE TABLE json_decimals(v DECFLOAT(12) PRIMARY KEY)",
  "INSERT INTO json_decimals VALUES(CAST('1e100' AS DECFLOAT)),(CAST('1.2300' AS DECFLOAT)),(CAST('NaN' AS DECFLOAT)),(CAST('Infinity' AS DECFLOAT)),(CAST('-Infinity' AS DECFLOAT))"])
queries << "TABLE json_decimals ORDER BY v"
changes << "INSERT INTO json_decimals VALUES(CAST('9.999' AS DECFLOAT(3)))"
schema.concat([
  "CREATE TABLE decimal_operands(a DECFLOAT(5),b DECFLOAT(3))",
  "INSERT INTO decimal_operands VALUES(1,6)",
  "CREATE TABLE decimal_defaults(v DECFLOAT(20) DEFAULT (SELECT a/(b+1E0) FROM decimal_operands),p DECFLOAT(20) DEFAULT (SELECT a/(b+CAST(1 AS DECFLOAT(8))) FROM decimal_operands),s DECFLOAT(20) DEFAULT (SELECT SUM(a)+AVG(b) FROM decimal_operands))",
  "INSERT INTO decimal_defaults DEFAULT VALUES",
  "CREATE TABLE decimal_results AS SELECT a+b AS a,a-b AS s,a*b AS m,a/b AS d FROM decimal_operands"
])
queries.concat(["TABLE decimal_defaults ORDER BY v", "TABLE decimal_results", "SELECT SUM(a) AS s,AVG(b) AS a FROM decimal_operands"])
changes.concat(["UPDATE decimal_operands SET b=8", "INSERT INTO decimal_defaults DEFAULT VALUES", "INSERT INTO decimal_results SELECT a+b,a-b,a*b,a/b FROM decimal_operands"])

intervals = [
  ["YEAR", "1"], ["MONTH", "2"], ["DAY", "3"], ["HOUR", "4"], ["MINUTE", "5"], ["SECOND", "6.123456789"],
  ["YEAR TO MONTH", "1-2"], ["DAY TO HOUR", "1 2"], ["DAY TO MINUTE", "1 2:3"], ["DAY TO SECOND", "1 2:3:4.123456789"],
  ["HOUR TO MINUTE", "1:2"], ["HOUR TO SECOND", "1:2:3.123456789"], ["MINUTE TO SECOND", "1:2.123456789"]
]
columns = intervals.each_with_index.map do |(qualifier, _text), index|
  fields = qualifier.split(" TO ")
  fields[0] += qualifier == "SECOND" ? "(5,9)" : "(5)"
  fields[-1] += "(9)" if fields.length > 1 && fields[-1] == "SECOND"
  "c#{index} INTERVAL #{fields.join(' TO ')}#{[6, 9].include?(index) ? ' UNIQUE' : ''}"
end
schema << "CREATE TABLE interval_types(id INT PRIMARY KEY,#{columns.join(',')})"
rows = (0...4).map do |row|
  values = intervals.map { |qualifier, text| row == 3 ? "NULL" : "INTERVAL '#{row == 2 ? '0' : "#{row == 1 ? '-' : ''}#{text}"}' #{qualifier}" }
  "(#{row + 1},#{values.join(',')})"
end
schema << "INSERT INTO interval_types VALUES#{rows.join(',')}"
schema << "CREATE TABLE interval_defaults(i INTERVAL DAY(5) TO SECOND(9) DEFAULT (SELECT MAX(c9) FROM interval_types),d INTERVAL YEAR(5) TO MONTH DEFAULT ((SELECT MAX(d) FROM calendar)-DATE '1999-01-01') YEAR TO MONTH)"
schema << "INSERT INTO interval_defaults DEFAULT VALUES"
schema << "CREATE TABLE interval_rows AS SELECT ROW(INTERVAL '1-6' YEAR TO MONTH,INTERVAL '-0.000000001' SECOND) AS pair"
queries.concat(["TABLE interval_types ORDER BY id", "TABLE interval_defaults ORDER BY i", "TABLE interval_rows",
  "SELECT id FROM interval_types WHERE c6=INTERVAL '14' MONTH", "SELECT SUM(c0) AS total,AVG(c2) AS average FROM interval_types"])
changes.concat(["UPDATE interval_types SET c9=c9+INTERVAL '0.000000001' SECOND,c6=c6+INTERVAL '1' MONTH WHERE id=1",
  "INSERT INTO interval_defaults DEFAULT VALUES", "DELETE FROM interval_types WHERE id=2",
  "INSERT INTO interval_types(id,c6,c9) VALUES(5,INTERVAL '15' MONTH,INTERVAL '1' DAY)"])

Dir.mktmpdir("sql-persistence-reference-") do |directory|
  [:none, :fast, :high].each do |compression|
    native = File.join(directory, "ruby-#{compression}")
    reference = File.join(directory, "java-#{compression}")
    compare.call(java_run.call(reference, schema), ruby_run.call(native, schema, compression: compression), "Schema #{compression}")
    compare.call(java_run.call(native, queries), ruby_run.call(reference, queries), "Cross-read #{compression}")
    compare.call(java_run.call(native, changes), ruby_run.call(reference, changes), "Cross-write #{compression}")
    compare.call(java_run.call(reference, queries), ruby_run.call(native, queries), "Reopen #{compression}")
    ddl = ["TRUNCATE TABLE pairs", "DROP TABLE pairs", "CREATE TABLE pairs(v VARCHAR DEFAULT 'recreated')", "INSERT INTO pairs DEFAULT VALUES", "TABLE pairs"]
    compare.call(java_run.call(reference, ddl), ruby_run.call(native, ddl), "DDL #{compression}")
    compare.call(java_run.call(native, ["TABLE pairs"]), ruby_run.call(reference, ["TABLE pairs"]), "DDL reopen #{compression}")
    rowids = java_run.call(native, ["SELECT _ROWID_,a,b FROM bag ORDER BY _ROWID_"]).first.fetch(:rows)
    assert.call(rowids == [["1.0", "1.0", "updated"], ["2.0", "1.0", "updated"], ["4.0", "2.0", "later"]], "Stable row ids differ: #{rowids.inspect}")
  end
  protected = File.join(directory, "protected")
  ruby_run.call(protected, ["CREATE TABLE t(v INT)", "INSERT INTO t VALUES(42)"], password: "sëcret 😀")
  assert.call(java_run.call(protected, ["TABLE t"], "sëcret 😀").first.fetch(:rows) == [["42.0"]], "Java rejected the native password hash")
  assert.call(ruby_run.call(protected, ["TABLE t"], password: "sëcret 😀", read_only: true).first.fetch(:rows) == [["42.0"]], "Native read-only password reopen differs")
  inferred_empty = File.join(directory, "inferred-empty-native")
  ruby_run.call(inferred_empty, ["CREATE TABLE empty_binary AS SELECT X'' AS v"])
  assert.call(java_run.call(inferred_empty, ["TABLE empty_binary"]).first.fetch(:rows) == [[""]], "Java cannot reopen native inferred empty binary metadata")
  invalid_empty = File.join(directory, "inferred-empty-java")
  assert.call(java_run.call(invalid_empty, ["CREATE TABLE empty_binary AS SELECT X'' AS v"]).first == {update: 0}, "Java empty binary CTAS failed before reopen")
  assert.call(java_run.call(invalid_empty, ["TABLE empty_binary"]).first[:error] == 42104, "Java zero-length binary metadata limitation changed")
  begin
    H2.connect(path: invalid_empty).close
    abort "Native parser accepted Java's invalid zero-length column metadata"
  rescue H2::Error => error
    assert.call(error.code == 90008, "Native invalid zero-length metadata rejection differs")
  end
  puts "Reference limitation: Java saves inferred empty binary columns with precision 0, then omits the table on reopen; native files use precision 1"
  child = <<~'RUBY'
    require "h2"
    database = H2::Database.new(path: ARGV.fetch(0))
    connection = database.connect
    connection.execute("BEGIN")
    connection.execute("UPDATE a SET v=20")
    connection.execute("UPDATE b SET v=30")
    if ARGV.fetch(1) == "decision"
      raw = database.instance_variable_get(:@storage).instance_variable_get(:@store)
      raw.define_singleton_method(:commit) do
        result = super()
        Process.kill(:KILL, Process.pid)
        result
      end
    end
    connection.commit unless ARGV.fetch(1) == "uncommitted"
    Process.kill(:KILL, Process.pid)
  RUBY
  [:uncommitted, :committed, :decision].each do |phase|
    path = File.join(directory, "crash-#{phase}")
    ruby_run.call(path, ["CREATE TABLE a(v INT)", "CREATE TABLE b(v INT)", "INSERT INTO a VALUES(10)", "INSERT INTO b VALUES(10)"])
    _output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", child, path, phase.to_s)
    assert.call(status.signaled? && status.termsig == 9, "SQL writer did not reach #{phase} state: #{error}")
    expected = phase == :uncommitted ? [["10.0", "10.0"]] : [["20.0", "30.0"]]
    query = ["SELECT a.v AS av,b.v AS bv FROM a CROSS JOIN b"]
    assert.call(ruby_run.call(path, query).first.fetch(:rows) == expected, "Native SQL crash recovery differs for #{phase}")
    assert.call(java_run.call(path, query).first.fetch(:rows) == expected, "JDBC cannot reopen SQL crash recovery for #{phase}")
  end
end

puts "SQL persistence: #{checks} cross-engine checks passed (native/JDBC catalog creation, data, keys, defaults, row ids, DDL, credentials and all compression modes)"

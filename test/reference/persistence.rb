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
type_name = ->(name) { name.start_with?("ROW(") ? "ROW" : {"CHARACTER VARYING" => "VARCHAR", "CHARACTER" => "CHAR", "DOUBLE PRECISION" => "DOUBLE", "BINARY VARYING" => "VARBINARY"}.fetch(name, name) }
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
          types = result.types.map(&:name)
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
  "CREATE TABLE binary_rows AS SELECT ROW(UUID '01234567-89ab-cdef-0123-456789abcdef',X'ff00') AS pair"
]
queries = ["TABLE people ORDER BY id", "TABLE pairs ORDER BY a,b", "TABLE bag ORDER BY a NULLS LAST,b NULLS LAST",
  "TABLE typed", "TABLE target", "TABLE rows_table", 'TABLE "odd""table"', "SELECT id FROM people WHERE name='Ada 😀'",
  "TABLE bytes ORDER BY u", "TABLE binary_defaults", "SELECT u FROM bytes WHERE v=X'00ffeda080'",
  "TABLE empty_binary", "TABLE binary_rows"]
changes = ["UPDATE people SET amount=amount+1 WHERE id=-7", "INSERT INTO people(id,name) VALUES(20,'new')",
  "DELETE FROM bag WHERE a IS NULL", "UPDATE bag SET b='updated' WHERE a=1", "INSERT INTO bag VALUES(2,'later')",
  "UPDATE source SET v=20", "INSERT INTO target DEFAULT VALUES", "INSERT INTO pairs VALUES('b',3,'z')",
  "INSERT INTO people VALUES(9,'duplicate',0,TRUE)", "INSERT INTO pairs VALUES('a',1,'dup')",
  "UPDATE bytes SET b=X'ff',v=X'80ff00' WHERE u='0123456789abcdef0123456789abcdef'",
  "DELETE FROM bytes WHERE u=UUID 'ffffffff-ffff-ffff-ffff-ffffffffffff'",
  "INSERT INTO bytes(u,v) VALUES('11111111-1111-1111-1111-111111111111',X'00')",
  "INSERT INTO bytes(u,v) VALUES('22222222-2222-2222-2222-222222222222',X'80ff00')",
  "INSERT INTO binary_defaults DEFAULT VALUES"]

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

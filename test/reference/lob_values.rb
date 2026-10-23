# frozen_string_literal: true

require 'open3'
require 'digest'
require 'tmpdir'
require 'fileutils'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2'
jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
oracle = File.join(__dir__,'LobSqlOracle.java')
units = ->(text) { H2::CharacterString.sort_key(text).unpack1('H*') }
value = lambda do |item,type|
  case item
  when nil then 'N'
  when H2::BlobValue then "B#{item.bytes.bytesize}:#{Digest::SHA256.hexdigest(item.bytes)}"
  when H2::ClobValue
    text = H2::CharacterString.sort_key(item.to_s)
    "C#{text.bytesize / 2}:#{Digest::SHA256.hexdigest(text)}:#{item.bytes.bytesize}:#{Digest::SHA256.hexdigest(item.bytes)}"
  when String then H2::BinaryString.binary?(item) ? "Y#{item.unpack1('H*')}" : "S#{units.call(item)}"
  when H2::ArrayValue then 'A[' + item.values.map { value.call(it,item.element_type) + ';' }.join + ']'
  when H2::RowValue then 'R[' + item.values.each_with_index.map { |field,i| value.call(field,item.type&.fields&.[](i)) + ';' }.join + ']'
  else
    text = case item
    when true then 'TRUE'
    when false then 'FALSE'
    when BigDecimal then H2::ArrayType.decimal_text(item,type&.scale || item.scale)
    when Float then H2::JsonValue.float_text(item,real: type&.name == 'REAL')
    else item.to_s
    end
    'V' + units.call(text)
  end
end
render = lambda do |result|
  next "U\t#{result.update_count}\n" unless result.query?

  lines = result.types.each_with_index.map do |type,i|
    name = type.respond_to?(:type_name) ? type.type_name : type.name
    name = H2::SQLTypeName::ALIASES.fetch(name,name) if type.is_a?(H2::Type)
    precision = type.precision || {'TINYINT'=>8,'SMALLINT'=>16,'INTEGER'=>32,'BIGINT'=>64,'REAL'=>24,'DOUBLE'=>53,'VARCHAR'=>1_000_000_000,'VARBINARY'=>1_000_000_000,'BOOLEAN'=>1,'NULL'=>1,'UUID'=>16}.fetch(type.name)
    "M\t#{units.call(result.columns[i])}\t#{units.call(name)}\t#{[precision,(1 << 31) - 1].min}\t#{type.scale || 0}"
  end
  result.rows.each { |row| lines << (['R'] + row.each_with_index.map { |item,i| value.call(item,result.types[i]) }).join("\t") }
  lines.join("\n") + "\n"
end
run_java = lambda do |statements,url = nil,*arguments|
  output,error,status = Open3.capture3(java,'-cp',jar,oracle,*[url].compact,*arguments,stdin_data: statements.map { [it].pack('m0') }.join("\n") + "\n")
  abort "#{error}\n#{output}" unless status.success?
  output.split("END\n")
end
run_native = lambda do |connection,sql|
  render.call(connection.execute(sql))
rescue H2::Error => error
  "E\t#{error.code}\t#{error.sql_state}\n"
end
statements = []
aliases = ['BLOB','BINARY LARGE OBJECT','TINYBLOB','MEDIUMBLOB','LONGBLOB','IMAGE','CLOB','CHARACTER LARGE OBJECT','CHAR LARGE OBJECT','NCLOB','NCHAR LARGE OBJECT','NATIONAL CHARACTER LARGE OBJECT']
aliases.product(['','(1)','(256)','(1K)','(1 M)','(10G)','(10T)','(1P)','(9223372036854775807)']).each do |name,limit|
  statements << "SELECT CAST(NULL AS #{name}#{limit}) AS v"
end
sources = ['NULL',"''","'abc'","'café'","'😀x'","U&'\\d800'","U&'\\d800a\\dc00'","X''","X'00ff'","X'f09f9880'",'1','CAST(-1 AS SMALLINT)','1.25','TRUE',"JSON '{\"a\":1}'",'ARRAY[1,2]','ROW(1,2)']
%w[BLOB CLOB].product(['','(1)','(2)','(3)','(85)','(86)','(256)','(257)'],sources).each do |name,limit,source|
  statements << "SELECT CAST(#{source} AS #{name}#{limit}) AS v"
  statements << "SELECT CAST(v AS #{name}#{limit}) AS v FROM (VALUES(#{source}),(#{source})) t(v)"
end
lobs = ["CAST('abc' AS CLOB)","CAST('42' AS CLOB)","CAST('😀x' AS CLOB)","CAST(X'00ff' AS BLOB)","CAST(X'0000002a' AS BLOB)","CAST(X'f09f9880' AS BLOB)"]
targets = ['CHAR(5)','VARCHAR(5)','BINARY(5)','VARBINARY(5)','BLOB(2)','CLOB(2)','BOOLEAN','TINYINT','SMALLINT','INT','BIGINT','NUMERIC(10,2)','REAL','DOUBLE','DECFLOAT(5)','UUID','JSON','DATE','TIME','TIMESTAMP','INT ARRAY','ROW(a INT)']
lobs.product(targets).each { |source,type| statements << "SELECT CAST(#{source} AS #{type}) AS v" }
lobs.each do |source|
  %w[CHAR_LENGTH OCTET_LENGTH BIT_LENGTH UPPER LOWER].each { statements << "SELECT #{it}(#{source}) AS v" }
  statements << "SELECT #{source} AS v,ARRAY[#{source}] AS a,ROW(#{source}) AS r"
  statements << "SELECT #{source} FORMAT JSON AS v,#{source} IS JSON AS j"
end
comparands = [*lobs,"'abc'","X'00ff'",'NULL']
comparands.product(comparands,['=','<','IS NOT DISTINCT FROM']).each do |left,right,operator|
  statements << "SELECT #{left} #{operator} #{right} AS v"
end
['BLOB(0)','CLOB(0)','BLOB(-1)','CLOB(-1)','BLOB(8192P)','CLOB(9223372036854775808)','BLOB(1K OCTETS)','CLOB(1K CHARACTERS)','CLOB(1K OCTETS)'].each do |type|
  statements << "SELECT CAST(NULL AS #{type}) AS v"
end
statements.concat([
  'CREATE TABLE t(id INT,b BLOB,c CLOB)',
  "INSERT INTO t VALUES(1,X'ff','z'),(2,X'00','😀'),(3,X'ff','z'),(4,NULL,NULL)",
  'SELECT b,COUNT(*) AS n FROM t GROUP BY b ORDER BY b',
  'SELECT c,COUNT(*) AS n FROM t GROUP BY c ORDER BY c',
  'SELECT MIN(b) AS lo,MAX(b) AS hi,MIN(c) AS cl,MAX(c) AS ch,COUNT(DISTINCT b) AS n FROM t',
  'SELECT ARRAY_AGG(b ORDER BY b) AS a,ARRAY_AGG(c ORDER BY c) AS c FROM t',
  "SELECT CAST('b' AS CLOB) AS v UNION SELECT 'a' ORDER BY 1",
  "SELECT CAST(X'62' AS BLOB) AS v UNION SELECT X'61' ORDER BY 1",
  "SELECT CAST('a' AS CLOB)||'b' AS c,CAST(X'61' AS BLOB)||X'62' AS b",
  'CREATE TABLE defaults(b BLOB DEFAULT (SELECT MAX(b) FROM t),c CLOB DEFAULT (SELECT MAX(c) FROM t))',
  'INSERT INTO defaults DEFAULT VALUES','TABLE defaults',
  'CREATE TABLE copied AS SELECT b,c FROM t','TABLE copied ORDER BY b,c','DROP TABLE copied','DROP TABLE defaults','DROP TABLE t'
])
['BLOB','CLOB','BLOB ARRAY','ROW(x CLOB)'].product(['PRIMARY KEY','UNIQUE']).each do |type,key|
  statements << "CREATE TABLE lob_key(v #{type} #{key})"
end
expected = run_java.call(statements)
abort 'SQL LOB result count differs' unless expected.length == statements.length
failures = []
H2.connect do |connection|
  statements.zip(expected).each_with_index do |(sql,wanted),index|
    actual = run_native.call(connection,sql)
    failures << "#{index}: #{sql}\nJava: #{wanted}\nRuby: #{actual}" unless actual == wanted
  end
end
abort failures.first(40).join("\n") + "\n#{failures.length} differences" unless failures.empty?
puts "SQL LOB values: #{statements.length} strict Java comparisons passed (aliases, precision, conversions, UTF-16, bytes, metadata, collections, comparisons, aggregates and defaults)"

expected = run_java.call([],'prepared')
actual = []
executions = 0
H2.connect do |connection|
  values = [nil,true,1,BigDecimal('1.25'),'abc','😀x',"\x00\xff".b,H2::BlobValue.new("\x00\xff".b),H2::BlobValue.new('😀'.b),H2::ClobValue.parse('abc'),H2::ClobValue.parse('😀x'),[1,2]]
  ['SELECT ? AS v','SELECT CAST(? AS BLOB) AS v','SELECT CAST(? AS CLOB) AS v','SELECT CAST(? AS BLOB(3)) AS v','SELECT CAST(? AS CLOB(3)) AS v',
    'SELECT CHAR_LENGTH(CAST(? AS BLOB)) AS l,OCTET_LENGTH(CAST(? AS CLOB)) AS o','SELECT ? FORMAT JSON AS v','SELECT ARRAY[CAST(? AS BLOB)] AS a'].each do |sql|
    statement = connection.prepare(sql)
    values.each do |item|
      executions += 1
      actual << begin
        render.call(statement.execute(*Array.new(statement.parameter_count,item)))
      rescue H2::Error => error
        "E\t#{error.code}\t#{error.sql_state}\n"
      end
    end
  end
  ['SELECT CAST(? AS BLOB(0))','SELECT CAST(? AS CLOB(8192P))','SELECT CAST(? AS CLOB(1K OCTETS))','SELECT CAST(? AS BLOB(1K OCTETS))'].each do |sql|
    actual << begin
      connection.prepare(sql)
      "P\tprepared\n"
    rescue H2::Error => error
      "P\t#{error.code}\t#{error.sql_state}\n"
    end
  end
end
failures = expected.zip(actual).each_with_index.filter_map { |(wanted,got),i| "#{i}: Java #{wanted.inspect}\nRuby #{got.inspect}" unless wanted == got }
abort "SQL LOB prepared result counts differ" unless expected.length == actual.length
abort failures.join("\n") unless failures.empty?
puts "SQL LOB parameters: #{executions} reused JDBC executions and four preparation checks passed (typed/untyped LOBs, bytes, UTF-16, casts, lengths, JSON and arrays)"

binary = Array.new(32768) { (it * 31 + 7) & 255 }.pack('C*')
replacement = Array.new(400000) { (it * 13 + 9) & 255 }.pack('C*')
text = '😀café' * 2000
changed = '漢😀' * 3000
quote = ->(item) { "'#{item.gsub("'","''")}'" }
blob = ->(item) { "X'#{item.unpack1('H*')}'" }
schema = [
  'CREATE TABLE t(id INT PRIMARY KEY,b BLOB(1M),c CLOB(1M),a BLOB ARRAY,r ROW(x CLOB,n INT))',
  "INSERT INTO t VALUES(1,#{blob.call(binary)},#{quote.call(text)},ARRAY[CAST(#{blob.call(binary.byteslice(0,1000))} AS BLOB)],ROW(CAST(#{quote.call(text[0,1000])} AS CLOB),7)),(2,X'00','small',NULL,NULL)",
  'CREATE TABLE saved(b BLOB DEFAULT (SELECT MAX(b) FROM t),c CLOB DEFAULT (SELECT MAX(c) FROM t))',
  'INSERT INTO saved DEFAULT VALUES'
]
queries = ['TABLE t ORDER BY id','TABLE saved','SELECT id,CHAR_LENGTH(b) AS bl,OCTET_LENGTH(b) AS bo,CHAR_LENGTH(c) AS cl,OCTET_LENGTH(c) AS co FROM t ORDER BY id']
changes = ['BEGIN',"UPDATE t SET b=X'ff',c='rollback' WHERE id=1",'ROLLBACK','BEGIN',
  "UPDATE t SET b=#{blob.call(replacement)},c=#{quote.call(changed)} WHERE id=1",'SAVEPOINT s','DELETE FROM t WHERE id=2','ROLLBACK TO SAVEPOINT s','COMMIT',
  'INSERT INTO t SELECT 3,b,c,a,r FROM t WHERE id=1','DELETE FROM t WHERE id=1','INSERT INTO saved DEFAULT VALUES']
checks = 0
run_file = lambda do |path,sql,compression|
  H2.connect(path: path,compression: compression) { |connection| sql.map { run_native.call(connection,it) } }
end
compare = lambda do |wanted,actual,label|
  abort "#{label}\nExpected: #{wanted.inspect}\nActual: #{actual.inspect}" unless actual == wanted
  checks += 1
end
Dir.mktmpdir('h2-sql-lob-files') do |directory|
  [:none,:fast,:high].each do |compression|
    java_path = File.join(directory,"java-#{compression}")
    ruby_path = File.join(directory,"ruby-#{compression}")
    url = ->(path) { "jdbc:h2:#{path}#{compression == :none ? '' : ';COMPRESS=TRUE'}" }
    compare.call(run_java.call(schema,url.call(java_path)),run_file.call(ruby_path,schema,compression),"Create SQL LOB files #{compression}")
    expected = run_java.call(queries,url.call(java_path))
    compare.call(expected,run_file.call(java_path,queries,compression),"Read JDBC SQL LOBs #{compression}")
    compare.call(expected,run_file.call(ruby_path,queries,compression),"Reopen native SQL LOBs #{compression}")
    compare.call(expected,run_java.call(queries,url.call(ruby_path)),"JDBC reads native SQL LOBs #{compression}")
    compare.call(run_java.call(changes,url.call(ruby_path)),run_file.call(java_path,changes,compression),"Cross-write SQL LOBs #{compression}")
    expected = run_java.call(queries,url.call(java_path))
    compare.call(expected,run_file.call(java_path,queries,compression),"Native reopens cross-written SQL LOBs #{compression}")
    compare.call(expected,run_file.call(ruby_path,queries,compression),"Native reads JDBC LOB changes #{compression}")
    compare.call(expected,run_java.call(queries,url.call(ruby_path)),"JDBC reopens LOB changes #{compression}")
    teardown = ['TRUNCATE TABLE t','DROP TABLE saved','DROP TABLE t']
    compare.call(run_java.call(teardown,url.call(ruby_path)),run_file.call(java_path,teardown,compression),"Remove cross-written LOBs #{compression}")
    H2::MVStore::Store.open("#{java_path}.mv.db",read_only: true) do |raw|
      abort "Native SQL cleanup leaked LOBs #{compression}" unless raw.open_map('lobMap').size.zero? && raw.open_map('lobData').size.zero? && raw.open_map('ruby.lobCleanup').size.zero?
      checks += 1
    end
  end
end
puts "SQL LOB persistence: #{checks} cross-engine file checks passed (external BLOB/CLOBs, shared copies, defaults, nested values, rollback/savepoints, replacement, deletion, cleanup and all compression modes)"

crash_checks = 0
Dir.mktmpdir('h2-sql-lob-crashes') do |directory|
  child = <<~'RUBY'
    require 'h2'
    database = H2::Database.new(path: ARGV.fetch(0))
    connection = database.connect
    connection.execute('BEGIN')
    connection.execute('UPDATE t SET b=?,c=?','new' * 10000,'漢new' * 10000)
    phase = ARGV.fetch(1).to_i
    Process.kill(:KILL,Process.pid) if phase.zero?
    raw = database.instance_variable_get(:@storage).instance_variable_get(:@store)
    calls = 0
    raw.define_singleton_method(:commit) do
      result = super()
      calls += 1
      Process.kill(:KILL,Process.pid) if calls == phase
      result
    end
    connection.commit
    abort 'Crash phase was not reached'
  RUBY
  4.times do |phase|
    path = File.join(directory,"crash-#{phase}")
    old_expected = H2.connect(path: path) do |connection|
      connection.execute('CREATE TABLE t(b BLOB,c CLOB)')
      connection.execute('INSERT INTO t VALUES(?,?)','old' * 10000,'😀old' * 10000)
      render.call(connection.execute('TABLE t'))
    end
    _output,error,status = Open3.capture3(RbConfig.ruby,'-I',File.join(root,'lib'),'-e',child,path,phase.to_s)
    abort "LOB crash phase #{phase} not reached: #{error}" unless status.signaled? && status.termsig == 9
    query = 'TABLE t'
    expected = H2.connect do |connection|
      connection.execute('CREATE TABLE t(b BLOB,c CLOB)')
      connection.execute('INSERT INTO t VALUES(?,?)',(phase.zero? ? 'old' : 'new') * 10000,(phase.zero? ? '😀old' : '漢new') * 10000)
      render.call(connection.execute(query))
    end
    if phase == 1
      probe = File.join(directory,'java-decision-probe')
      FileUtils.cp("#{path}.mv.db","#{probe}.mv.db")
      observed = run_java.call([query],"jdbc:h2:#{probe}")
      abort 'Java committed-decision LOB observation changed' unless observed == [old_expected]
      compare.call([expected],run_file.call(path,[query],:none),"Native LOB decision recovery #{phase}")
      compare.call([expected],run_java.call([query],"jdbc:h2:#{path}"),"JDBC reads native LOB decision recovery #{phase}")
    else
      compare.call([expected],run_java.call([query],"jdbc:h2:#{path}"),"JDBC LOB crash recovery #{phase}")
      compare.call([expected],run_file.call(path,[query],:none),"Native LOB crash recovery #{phase}")
    end
    H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
      abort "Recovered LOB cleanup leaked references #{phase}" unless raw.open_map('lobMap').size == 2 && raw.open_map('tempLobMap').size.zero? && raw.open_map('ruby.lobCleanup').size.zero?
    end
    crash_checks += 4
  end
end
puts "SQL LOB recovery: #{crash_checks} checks passed after process death before commit, after the durable decision, after row commit and after reference cleanup (JDBC/native values and reclaimed references)"
puts 'Java committed-decision recovery defect also reproduced for LOB rows on a separate copy; native recovery preserves the durable decision before JDBC reopen (not counted as a Java match)'

Dir.mktmpdir('h2-empty-lob-catalog') do |directory|
  java_path = File.join(directory,'java')
  ruby_path = File.join(directory,'ruby')
  expected = run_java.call([],'empty',"jdbc:h2:#{java_path}")
  abort 'Java empty LOB catalog observation changed' unless run_java.call(['TABLE e'],"jdbc:h2:#{java_path}") == ["E\t42104\t42S04\n"]
  H2.connect(path: ruby_path) { it.execute('CREATE TABLE e AS SELECT ? AS b,? AS c',H2::BlobValue.new(''),H2::ClobValue.parse('')) }
  [java_path,ruby_path].each do |path|
    actual = run_file.call(path,['TABLE e'],:none)
    abort "Native empty LOB catalog differs: #{actual.inspect}" unless actual == expected
  end
  abort 'Java empty native LOB catalog observation changed' unless run_java.call(['TABLE e'],"jdbc:h2:#{ruby_path}") == ["E\t42104\t42S04\n"]
end
puts 'Java empty inferred LOB catalog defect reproduced for both engines CTAS files; native metadata recovery preserves zero-precision LOB columns and rows (not counted as Java file matches)'

# frozen_string_literal: true

require 'open3'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2'
jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
oracle = File.join(__dir__,'RowOracle.java')
statements = []
declarations = ['ROW(a INT)','ROW(a INT,b INT)','ROW("a" VARCHAR(5),b VARCHAR(5))','ROW(n NUMERIC(6,2),m NUMERIC(6,2))',
  "ROW(a ENUM('z','a'),b ENUM('z','a'))",'ROW(a INT ARRAY,b INT ARRAY)','ROW(a ROW(x INT),b ROW(x INT))']
values = ['NULL','1',"'1'",'ROW()','ROW(1)','ROW(1,2)','ROW(NULL,NULL)',"ROW('1','2')",'ROW(1,2,3)',
  'ROW(1.25,2.50)','ROW(ARRAY[1,2],ARRAY[3])','ROW(ROW(1),ROW(2))',"ROW('missing','2')"]
declarations.product(values).each do |type,value|
  statements << "SELECT CAST(#{value} AS #{type}) AS r"
  statements << "SELECT CAST(v AS #{type}) AS r FROM (VALUES(#{value}),(#{value})) t(v)"
end
['ROW()','ROW(a INT,A INT)','ROW(a INT,)','ROW(a)','ROW(a INT b INT)'].each { statements << "SELECT CAST(NULL AS #{it}) AS r" }
rows = ['ROW(1,2)','ROW(NULL,NULL)','CAST(NULL AS ROW(a INT,b INT))','CAST(ROW(1,2) AS ROW(a INT,b INT))',
  'CAST(ROW(1,2) AS ROW("a" INT,"b" INT))','CAST(ROW(1.25,2.50) AS ROW(a NUMERIC(6,2),b NUMERIC(6,2)))',
  'CAST(ROW(ARRAY[1,2],ARRAY[3]) AS ROW(a INT ARRAY,b INT ARRAY))',
  'CAST(ROW(ROW(1),ROW(2)) AS ROW(a ROW(x INT),b ROW(x INT)))']
rows.product(%w[c1 c2 a b x],['',' WHERE FALSE']).each { |row,name,tail| statements << "SELECT (#{row}).#{name} AS v#{tail}" }
rows.each do |row|
  statements << "SELECT #{row} AS r"
  statements << "SELECT (ARRAY[#{row}][1]).a AS v"
end
rows.first(4).product(rows.first(4),['=','<>','<','IS DISTINCT FROM','IS NOT DISTINCT FROM']).each do |left,right,operator|
  statements << "SELECT #{left} #{operator} #{right} AS v"
end
["JSON '{\"a\":1,\"b\":null,\"a\":2}'","JSON '[1,2]'","JSON 'null'","JSON '3'",'CAST(NULL AS JSON)'].product(['"a"','"b"','"missing"','a']).each do |value,name|
  statements << "SELECT (#{value}).#{name} AS v"
end
['1','NULL',"'text'",'ARRAY[1]','?'].each { statements << "SELECT (#{it}).a AS v WHERE FALSE" }
statements.concat([
  'SELECT ROW(NULL)=ROW(NULL,NULL)','SELECT ROW(1)=ROW(1,2)','SELECT ROW(1,2)=ROW(1,2,3)',
  'SELECT ROW(1,2)=1','SELECT ROW(NULL)=ROW(1,2)','SELECT 1=ROW()',
  'SELECT ROW(NULL,NULL)=ROW(NULL)','SELECT ROW(1) UNION SELECT ROW(1,2)',
  'SELECT (),ROW()',
  'CREATE TABLE items(id INT PRIMARY KEY,r ROW(a INT,b VARCHAR(5)),n ROW(x ROW(y INT),z INT ARRAY))',
  "INSERT INTO items VALUES(1,ROW(1,'one'),ROW(ROW(7),ARRAY[1,2])),(2,ROW(2,'two'),NULL),(3,NULL,ROW(ROW(NULL),ARRAY[]))",
  'SELECT id,(r).a,(r).b,((n).x).y,(n).z FROM items ORDER BY id',
  'SELECT (r).a AS a,COUNT(*) AS n FROM items GROUP BY (r).a ORDER BY a',
  'SELECT id FROM items outer_t WHERE (r).a=(SELECT MAX((r).a) FROM items) ORDER BY id',
  'SELECT (x).a FROM (SELECT r AS x FROM items) t ORDER BY (x).a',
  'SELECT r FROM items UNION SELECT CAST(ROW(5,\'five\') AS ROW(x INT,y VARCHAR(5))) ORDER BY r',
  'SELECT ARRAY_AGG(r ORDER BY id) AS a FROM items',
  'CREATE TABLE saved(r ROW(a INT,b VARCHAR(5)) DEFAULT (SELECT r FROM items WHERE id=1),n INT DEFAULT (SELECT MAX((r).a) FROM items))',
  'INSERT INTO saved DEFAULT VALUES',"UPDATE items SET r=ROW(4,'four') WHERE id=1",'INSERT INTO saved DEFAULT VALUES','TABLE saved ORDER BY r',
  'CREATE TABLE keys(r ROW(a INT,b INT) PRIMARY KEY)','INSERT INTO keys VALUES(ROW(1,2)),(ROW(1,NULL)),(ROW(2,1))',
  'INSERT INTO keys VALUES(ROW(1,2))','TABLE keys ORDER BY r','DROP TABLE keys',
  'CREATE TABLE copied AS SELECT r,n FROM items','TABLE copied ORDER BY r','DROP TABLE copied'
])
['a','á','😀','space name','a"b','SELECT','VALUE','COUNT','key','CURRENT_DATE','_1'].each do |name|
  identifier = '"' + name.gsub('"','""') + '"'
  statements.concat([
    "SELECT CAST(ROW(1,2) AS ROW(#{identifier} INT,b INT)) AS r",
    "SELECT (CAST(ROW(1,2) AS ROW(#{identifier} INT,b INT))).#{identifier}",
    "CREATE TABLE named(r ROW(#{identifier} INT,b INT ARRAY[2]))",
    'INSERT INTO named VALUES(ROW(1,ARRAY[2]))',
    "SELECT (r).#{identifier},r FROM named",'DROP TABLE named'
  ])
end
statements.concat([
  "SELECT CAST(ROW(CAST(U&'\\d800' AS ENUM(U&'\\d800','😀')),ARRAY[U&'\\d800']) AS ROW(a ENUM(U&'\\d800','😀'),b ENUM(U&'\\d800','😀') ARRAY)) AS r",
  "SELECT ARRAY[CAST(ROW(U&'\\d800') AS ROW(a ENUM(U&'\\d800','😀')))] AS r",
  "SELECT CAST(ROW(1) AS ROW(U&\"\\d800\" INT)) AS r",
  "SELECT ARRAY[CAST(ROW(1) AS ROW(U&\"\\d800\" INT))] AS r",
  "SELECT CAST(ROW(1) AS ROW(U&\"\\d800\" INT)).U&\"\\d800\" AS r",
  "SELECT (JSON '{\"a\":1}').\"a\"",
  'SELECT ROW(1,2) IS NULL AS n,ROW(NULL,NULL) IS NULL AS z,ROW(1,NULL) IS NOT NULL AS v'
])

units = ->(text) { text.nil? ? 'null' : H2::CharacterString.sort_key(text).unpack1('H*') }
render = lambda do |result|
  next "U\t#{result.update_count}\n" unless result.query?

  lines = result.types.each_with_index.map do |type,i|
    name = type.respond_to?(:type_name) ? type.type_name : type.name
    name = H2::SQLTypeName::ALIASES.fetch(name,name) if type.is_a?(H2::Type)
    precision = type.precision || {'TINYINT'=>8,'SMALLINT'=>16,'INTEGER'=>32,'BIGINT'=>64,'REAL'=>24,'DOUBLE'=>53,'VARCHAR'=>1_000_000_000,'BOOLEAN'=>1,'NULL'=>1}.fetch(type.name)
    "M\t#{units.call(result.columns[i])}\t#{units.call(name)}\t#{precision}\t#{type.scale || 0}"
  end
  result.rows.each do |row|
    lines << (['R'] + row.each_with_index.map do |value,i|
      text = case value
      when nil then nil
      when true then 'TRUE'
      when false then 'FALSE'
      when BigDecimal then H2::ArrayType.decimal_text(value,result.types[i].scale)
      when Float then H2::JsonValue.float_text(value,real: result.types[i].name == 'REAL')
      else value.to_s
      end
      units.call(text)
    end).join("\t")
  end
  lines.join("\n") + "\n"
end
run_java = lambda do |queries, url = nil|
  input = queries.map { [it].pack('m0') }.join("\n") + "\n"
  output,error,status = Open3.capture3(java,'-cp',jar,oracle,*[url].compact,stdin_data: input)
  abort error unless status.success?
  output.split("END\n")
end
expected = run_java.call(statements)
abort 'ROW reference result count differs' unless expected.length == statements.length
failures = []
H2.connect do |connection|
  statements.zip(expected).each_with_index do |(sql,wanted),index|
    actual = begin
      render.call(connection.execute(sql))
    rescue H2::Error => error
      "E\t#{error.code}\t#{error.sql_state}\n"
    end
    failures << "#{index}: #{sql}\nJava: #{wanted}\nRuby: #{actual}" unless actual == wanted
  end
end
abort failures.join("\n") unless failures.empty?
puts "ROW: #{statements.length} strict Java comparisons passed (declarations, field names, nested types, casts, values, precision/scale, fields, JSON access, predicates, groups, sets, arrays, keys and defaults)"

expected,error,status = Open3.capture3(java,'-cp',jar,oracle,'prepared')
abort error unless status.success?
actual = []
executions = 0
H2.connect do |connection|
  values = [nil,1,'text',H2::RowValue.new([1]),H2::RowValue.new([1,2]),H2::RowValue.new([nil,2]),H2::RowValue.new(['1','2']),H2::RowValue.new(['bad','2'])]
  dump = lambda do |statement,value|
    executions += 1
    actual << render.call(statement.execute(value))
  rescue H2::Error => error
    actual << "E\t#{error.code}\t#{error.sql_state}\n"
  end
  ['SELECT CAST(? AS ROW(a INT,b INT)) AS r','SELECT (CAST(? AS ROW(a INT,b INT))).a AS a','SELECT (CAST(? AS ROW(a INT,b INT))).b AS b'].each do |sql|
    statement = connection.prepare(sql)
    values.each { dump.call(statement,it) }
  end
  type = H2::RowType.new(fields: [H2::Type.new('INTEGER',32,0),H2::Type.new('VARCHAR',nil,nil)],names: ['ID','LABEL'])
  typed = type.convert(H2::RowValue.new([1,'one']))
  ['SELECT CAST(? AS ROW(id INT,label VARCHAR)) AS r','SELECT (CAST(? AS ROW(id INT,label VARCHAR))).label AS label'].each do |sql|
    statement = connection.prepare(sql)
    [nil,typed,H2::RowValue.new([2,'two'])].each { dump.call(statement,it) }
  end
  ['SELECT (?).a','SELECT (ROW(1)).missing WHERE FALSE','SELECT (1).a WHERE FALSE','SELECT CAST(? AS ROW(a INT,A INT))','SELECT (CAST(? AS ROW(a INT))).a'].each do |sql|
    begin
      connection.prepare(sql)
      actual << "P\tprepared\n"
    rescue H2::Error => error
      actual << "P\t#{error.code}\t#{error.sql_state}\n"
    end
  end
end
abort "ROW JDBC differs:\nJava: #{expected}\nRuby: #{actual.join}" unless actual.join == expected
puts "ROW: #{executions} JDBC executions and five preparation checks passed (typed/untyped/null bindings, field access, descriptors, metadata and conversion errors)"

expected,error,status = Open3.capture3(java,'-cp',jar,oracle,'limits')
abort error unless status.success?
actual = []
H2.connect do |connection|
  [16_384,16_385].each do |count|
    fields = count.times.map { "c#{it} INT" }.join(',')
    values = Array.new(count,'1').join(',')
    ["SELECT CAST(NULL AS ROW(#{fields}))","SELECT ROW(#{values})"].each do |sql|
      begin
        connection.prepare(sql)
        actual << "L\t#{count}\tprepared\n"
      rescue H2::Error => error
        actual << "L\t#{count}\t#{error.code}\n"
      end
    end
  end
end
abort "ROW field limits differ:\n#{expected}\n#{actual.join}" unless actual.join == expected
puts 'ROW: four Java field-limit checks passed (16,384/16,385 value and declaration fields)'

bugs = ["SELECT CAST(ROW('1','word') AS ROW(a INT,b VARCHAR)) AS r",
  "SELECT JSON_ARRAY((CAST(ROW('1',2) AS ROW(a INT,b VARCHAR))).b) AS j",
  "SELECT CAST(ROW(U&'\\d800',ARRAY[U&'\\d800']) AS ROW(a ENUM(U&'\\d800'),b ENUM(U&'\\d800') ARRAY)) AS r"]
observed = run_java.call(bugs)
abort 'Java ROW conversion limitation changed' unless observed[0] == "E\t22018\t22018\n" && observed[2] == "E\t22018\t22018\n" && observed[1].end_with?("R\t005b0032005d\n")
H2.connect do |connection|
  raise 'Native ROW conversion lost field types' unless connection.execute(bugs[0]).rows.first.first.values == [1,'word']
  raise 'Native ROW field conversion lost character type' unless connection.execute(bugs[1]).rows.first.first.to_s == '["2"]'
  text = H2::CharacterString.sort_key(connection.execute(bugs[2]).rows.first.first.to_s).unpack('n*')
  raise 'Native ROW conversion lost UTF-16 fields' unless text == [82,79,87,32,40,0xd800,44,32,91,0xd800,93,41]
end
puts 'Java ROW limitation reproduced in three probes: after a changed component, later fields reuse its type; native conversion independently retains each declared field type (not counted as Java matches)'

require 'tmpdir'
schema = [
  'CREATE TABLE items(id INT PRIMARY KEY,r ROW("id" INT,"label" VARCHAR(5)),n ROW(x ROW(v INT),a ENUM(\'z\',\'a\') ARRAY),u ROW(v ENUM(U&\'\\d800\',\'😀\')))',
  "INSERT INTO items VALUES(1,ROW(1,'one'),ROW(ROW(7),ARRAY['z','a']),ROW(CAST(U&'\\d800' AS ENUM(U&'\\d800','😀')))),(2,ROW(2,'two'),NULL,ROW(CAST('😀' AS ENUM(U&'\\d800','😀')))),(3,NULL,ROW(ROW(NULL),ARRAY[]),NULL)",
  'CREATE TABLE saved(r ROW("id" INT,"label" VARCHAR(5)) DEFAULT (SELECT r FROM items WHERE id=1),v VARCHAR(5) DEFAULT (SELECT (r)."label" FROM items WHERE id=1))',
  'INSERT INTO saved DEFAULT VALUES',
  'CREATE TABLE copied AS SELECT r,n,u FROM items',
  'CREATE TABLE empty_rows AS SELECT r FROM items WHERE FALSE',
  'CREATE TABLE keys(r ROW(a INT,b INT) PRIMARY KEY)',
  'INSERT INTO keys VALUES(ROW(1,2)),(ROW(1,NULL)),(ROW(2,1))'
]
queries = ['SELECT id,r,(r)."id",(r)."label",n,((n).x).v,u FROM items ORDER BY id','TABLE saved ORDER BY r','TABLE copied ORDER BY r','TABLE empty_rows ORDER BY r','TABLE keys ORDER BY r','TABLE captured']
changes = ["UPDATE items SET r=ROW(4,'four') WHERE id=1",'DELETE FROM items WHERE id=3','INSERT INTO saved DEFAULT VALUES',
  'INSERT INTO copied SELECT r,n,u FROM items WHERE id=1','INSERT INTO empty_rows SELECT r FROM items WHERE id=2',
  'INSERT INTO keys VALUES(ROW(1,2))','DELETE FROM keys WHERE r=ROW(2,1)']
native = lambda do |path,zero,compression,commands|
  H2.connect(path: path,zero_based_enums: zero,compression: compression) do |connection|
    commands.map do |sql|
      begin
        render.call(connection.execute(sql))
      rescue H2::Error => error
        "E\t#{error.code}\t#{error.sql_state}\n"
      end
    end
  end
end
file_checks = 0
Dir.mktmpdir('h2-row-reference') do |directory|
  [false,true].product([:none,:fast,:high]).each do |zero,compression|
    java_path = File.join(directory,"java-#{zero}-#{compression}")
    ruby_path = File.join(directory,"ruby-#{zero}-#{compression}")
    java_url = "jdbc:h2:#{java_path};ZERO_BASED_ENUMS=#{zero}"
    ruby_url = "jdbc:h2:#{ruby_path};ZERO_BASED_ENUMS=#{zero}"
    expected = run_java.call(schema,java_url)
    actual = native.call(ruby_path,zero,compression,schema)
    abort "ROW file schema differs: #{expected.inspect}\n#{actual.inspect}" unless actual == expected && expected.none? { it.start_with?("E\t") }
    file_checks += 1
    captured_type = H2::RowType.new(fields: [H2::Type.new('NUMERIC',6,2),H2::Type.new('VARCHAR',5,nil),H2::Type.new('TINYINT',8,0),H2::Type.new('BINARY',2,nil)],names: ['N','LABEL','SMALL','BYTES'])
    actual = H2.connect(path: ruby_path,zero_based_enums: zero,compression: compression) do |connection|
      created = connection.execute('CREATE TABLE captured(r ROW(n NUMERIC(6,2),label VARCHAR(5),small TINYINT,bytes BINARY(2)) DEFAULT ?)',captured_type.convert(H2::RowValue.new([BigDecimal('1.20'),'one',-128,"\x0a\xff".b])))
      inserted = connection.execute('INSERT INTO captured DEFAULT VALUES')
      [created,inserted].map { render.call(it) }
    end
    expected = run_java.call(["CREATE TABLE captured(r ROW(n NUMERIC(6,2),label VARCHAR(5),small TINYINT,bytes BINARY(2)) DEFAULT ROW(CAST(1.20 AS NUMERIC(6,2)),'one',CAST(-128 AS TINYINT),CAST(X'0aff' AS BINARY(2))))",'INSERT INTO captured DEFAULT VALUES'],java_url)
    abort 'Captured row setup differs' unless actual == expected && expected == ["U\t0\n","U\t1\n"]
    file_checks += 1
    expected = run_java.call(queries,java_url)
    [native.call(java_path,zero,compression,queries),native.call(ruby_path,zero,compression,queries),run_java.call(queries,ruby_url)].each do |actual|
      abort "ROW initial file differs: #{zero}/#{compression}\n#{expected.inspect}\n#{actual.inspect}" unless actual == expected
      file_checks += 1
    end
    actual = native.call(java_path,zero,compression,changes)
    expected = run_java.call(changes,ruby_url)
    abort "ROW file updates differ: #{expected.inspect}\n#{actual.inspect}" unless actual == expected
    file_checks += 1
    expected = run_java.call(queries,java_url)
    [native.call(java_path,zero,compression,queries),native.call(ruby_path,zero,compression,queries),run_java.call(queries,ruby_url)].each do |actual|
      abort "ROW updated file differs: #{zero}/#{compression}\n#{expected.inspect}\n#{actual.inspect}" unless actual == expected
      file_checks += 1
    end
  end
end
puts "ROW: #{file_checks} cross-engine file comparisons passed (both ENUM bases, all compression modes, named/nested fields, UTF-16 metadata/values, arrays, keys, CTAS, empty results and dynamic defaults)"

Dir.mktmpdir('h2-empty-row-reference') do |directory|
  java_path = File.join(directory,'java')
  ruby_path = File.join(directory,'ruby')
  sql = 'CREATE TABLE t AS SELECT ROW() AS r,ARRAY[ROW()] AS a'
  query = 'TABLE t'
  observed = run_java.call([sql],"jdbc:h2:#{java_path}")
  abort 'Java empty ROW CTAS changed' unless observed == ["U\t0\n"]
  native.call(ruby_path,false,:none,[sql])
  [java_path,ruby_path].each do |path|
    H2.connect(path: path) do |connection|
      result = connection.execute(query)
      raise 'Empty ROW catalog recovery mismatch' unless result.types.map(&:type_name) == ['ROW()','ROW() ARRAY'] && result.rows.first.map(&:to_s) == ['ROW ()','[ROW ()]']
    end
    observed = run_java.call([query],"jdbc:h2:#{path}")
    abort "Java empty ROW reopen limitation changed: #{observed.inspect}" unless observed == ["E\t42104\t42S04\n"]
  end
end
puts 'Java empty ROW catalog limitation reproduced for Java/native CTAS files: Java omits the table on reopen; native catalog recovery retains empty rows and arrays (not counted as Java matches)'

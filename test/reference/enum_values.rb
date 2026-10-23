# frozen_string_literal: true

require 'open3'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2'
statements = []
types = ["ENUM('z','a','b')","ENUM(' ZERO ','one','two')","ENUM('a''b','😀','ß')","ENUM(1,2,TRUE)"]
values = ['NULL','0','1','2','3','4','-1','1.5','1.5E0','CAST(2 AS BIGINT)','CAST(1 AS REAL)','CAST(1 AS DOUBLE)','TRUE',"'z'","' A '","'one'","'2'","'missing'","X'7a'","DATE '2000-01-01'",'ARRAY[1]','ROW(1,2)',"JSON '1'"]
types.product(values).each do |type,value|
  statements << "SELECT CAST(#{value} AS #{type});"
  statements << "SELECT CAST(v AS #{type}) AS v FROM (VALUES(#{value}),(#{value})) t(v);"
end
["ENUM()","ENUM('')","ENUM(' ')","ENUM(NULL)","ENUM('a',' A ')","ENUM('ß','ss')","ENUM('ı','I')","ENUM('x','y')","ENUM('ab','😀')","ENUM('a'||'b',2+1)"].each do |type|
  statements << "SELECT CAST(NULL AS #{type});"
end
enums = ["CAST(1 AS ENUM('z','a','b'))","CAST(2 AS ENUM('z','a','b'))","CAST(1 AS ENUM('a','z'))","CAST(NULL AS ENUM('z','a','b'))"]
enums.product(['TINYINT','SMALLINT','INT','BIGINT','NUMERIC(8,2)','REAL','DOUBLE','DECFLOAT(8)','VARCHAR','CHAR(4)','BOOLEAN','VARBINARY','JSON','DATE']).each do |value,type|
  statements << "SELECT CAST(#{value} AS #{type}) AS v;"
end
others = values + enums
[enums[0],enums[1]].product(others,%w[+ - * / = <> < > <= >=]).each do |value,other,operator|
  statements << "SELECT #{value} #{operator} #{other} AS v;"
  statements << "SELECT #{other} #{operator} #{value} AS v;"
end
enums.product(%w[ABS SIGN ROUND BITCOUNT SUM AVG MIN MAX]).each do |value,name|
  statements << "SELECT #{name}(#{value}) AS v;"
end
enums.each { statements << "SELECT +#{it} AS p,-#{it} AS n;" }
statements.concat([
  "SELECT CAST(CAST(U&'\\d800' AS ENUM(U&'\\d800')) AS JSON) AS j;",
  "SELECT CAST(CAST(1 AS ENUM('TRUE')) AS BOOLEAN) AS b;",
  "SELECT CAST(CAST(1 AS ENUM('2000-01-01')) AS DATE) AS d;",
  "SELECT CAST(CAST(1 AS ENUM('00000000-0000-0000-0000-000000000001')) AS UUID) AS u;",
  "SELECT CAST(1 AS ENUM('a','b'))=ROW(1) AS b;",
  "SELECT CAST(1 AS ENUM('a','b'))+ROW(1) AS b;",
  "CREATE TABLE t(e ENUM('z','a','b') UNIQUE);", "INSERT INTO t VALUES('a'),('z'),(3),(NULL);",
  'TABLE t ORDER BY e;', "INSERT INTO t VALUES(' Z ');", 'SELECT e,COUNT(*) FROM t GROUP BY e ORDER BY e;',
  'SELECT MIN(e),MAX(e),COUNT(DISTINCT e) FROM t;',
  "SELECT e FROM t WHERE e IN('Z',' b ') ORDER BY e;", "SELECT e FROM t WHERE e BETWEEN 'z' AND 'a' ORDER BY e;",
  "SELECT e,e IS OF(ENUM('z','a','b')),e IS OF(ENUM('a','z')) FROM t ORDER BY e;",
  "SELECT CAST(1 AS ENUM('z','a')) AS v UNION SELECT 'a' ORDER BY v;",
  "SELECT CAST(1 AS ENUM('z','a')) AS v UNION SELECT 2 ORDER BY v;",
  "SELECT CAST(1 AS ENUM('z','a')) AS v UNION SELECT CAST(1 AS ENUM('a','z')) ORDER BY v;",
  "SELECT ARRAY[CAST(1 AS ENUM('z','a')),CAST(2 AS ENUM('z','a'))] AS v;",
  "SELECT ARRAY_CONTAINS(ARRAY[CAST(1 AS ENUM('z','a'))],' Z ') AS v;",
  "SELECT CAST(ARRAY_AGG(e ORDER BY e) AS VARCHAR) AS v FROM t;",
  "SELECT CASE e WHEN ' Z ' THEN 'yes' ELSE 'no' END AS v FROM t ORDER BY e;",
  "CREATE TABLE saved(e ENUM('z','a','b') DEFAULT (SELECT MIN(e) FROM t));",'INSERT INTO saved DEFAULT VALUES;',
  "DELETE FROM t WHERE e='z';",'INSERT INTO saved DEFAULT VALUES;','TABLE saved ORDER BY e;'
])
output,error,status = Open3.capture3(RbConfig.ruby,File.join(__dir__,'compare.rb'),'-',stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "ENUM: #{statements.length} generated Java comparisons passed (labels, declarations, ordinals, casts, arithmetic, comparisons, aggregates, collections and defaults)"

jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
expected,error,status = Open3.capture3(java,'-cp',jar,File.join(__dir__,'EnumOracle.java'))
abort error unless status.success?
executions = 0
units = ->(text) { text.nil? ? 'null' : H2::CharacterString.sort_key(text).unpack1('H*') }
render = lambda do |result|
  rendered = []
    result.types.each_with_index do |type,i|
        name = type.respond_to?(:type_name) ? type.type_name : type.name
        precision = type.precision || {'TINYINT'=>8,'INTEGER'=>32,'REAL'=>24,'DOUBLE'=>53,'VARCHAR'=>1_000_000_000,'BOOLEAN'=>1}.fetch(type.name)
        rendered << "M\t#{units.call(result.columns[i])}\t#{units.call(name)}\t#{precision}\t#{type.scale || 0}"
      end
      result.rows.each do |row|
        values = row.each_with_index.map do |value,i|
          text = case value
          when nil then nil
          when BigDecimal then H2::ArrayType.decimal_text(value,result.types[i].scale)
          when Float then H2::JsonValue.float_text(value,real: result.types[i].name == 'REAL')
          when true then 'TRUE'
          when false then 'FALSE'
          else value.to_s
          end
          units.call(text) + (value.is_a?(H2::EnumValue) ? ":#{value.ordinal}" : '')
        end
        rendered << (['R']+values).join("\t")
      end
  rendered.join("\n") + "\n"
end
lines = []
[false,true].each do |zero_based|
  H2.connect(zero_based_enums: zero_based) do |connection|
    dump = lambda do |statement,*parameters|
      executions += 1
      result = statement.execute(*parameters)
      lines.concat(render.call(result).lines.map(&:chomp))
    rescue H2::Error => error
      lines << "E\t#{error.code}\t#{error.sql_state}"
    end
    type = H2::EnumType.new(['z','A','😀'," quote' "])
    typed = type.value('A',zero_based: zero_based)
    values = [nil,' z ','a','😀',"QUOTE'",'1','missing',0,1,2,3,4,5,-1,2147483648,BigDecimal('1.5'),BigDecimal('2.5'),1.0,Float::NAN,true,"\x7a".b,typed]
    declaration = "ENUM('z','A','😀',' quote'' ')"
    statement = connection.prepare("SELECT CAST(? AS #{declaration}) AS e")
    values.each { dump.call(statement,it) }
    ['TINYINT','INT','NUMERIC(8,2)','REAL','DOUBLE','DECFLOAT(8)','VARCHAR','BOOLEAN','JSON'].each do |target|
      statement = connection.prepare("SELECT CAST(CAST(? AS #{declaration}) AS #{target}) AS v")
      [nil,0,1,2,'a',typed].each { dump.call(statement,it) }
    end
    statement = connection.prepare("SELECT CAST(? AS #{declaration})+? AS n")
    [['a',1],['a','1'],['a','1.5'],[nil,'bad'],['a',2147483647]].each { dump.call(statement,*it) }
    connection.execute("CREATE TABLE t(e #{declaration} PRIMARY KEY)")
    ['z','A','😀'," quote' "].each { connection.execute('INSERT INTO t VALUES(?)',it) }
    statement = connection.prepare('SELECT e,CAST(e AS INT) AS n FROM t WHERE e>=? ORDER BY e')
    ['z',' A ','😀',nil,'missing'].each { dump.call(statement,it) }
    dump.call(connection.prepare('SELECT MIN(e) AS lo,MAX(e) AS hi,ARRAY_AGG(e ORDER BY e) AS a FROM t'))
    statement = connection.prepare("SELECT CAST(? AS ENUM(U&'\\d800','😀')) AS e")
    [[0xd800].pack('n').force_encoding(Encoding::UTF_16BE),'😀',nil].each { dump.call(statement,it) }
    ["SELECT CAST(? AS ENUM('z','a'))","SELECT CAST('bad' AS ENUM('z','a')) WHERE FALSE","SELECT CAST(NULL AS ENUM('a',' A '))", "SELECT CAST(1 AS ENUM('z','a'))=1","SELECT -CAST(1 AS ENUM('z','a'))"].each do |query|
      begin
        connection.prepare(query)
        lines << "P\tprepared"
      rescue H2::Error => error
        lines << "P\t#{error.code}\t#{error.sql_state}"
      end
    end
  end
end
actual = lines.join("\n") + "\n"
if actual != expected
  File.write('/tmp/ruby-h2-enum-java.txt',expected)
  File.write('/tmp/ruby-h2-enum-ruby.txt',actual)
  abort 'ENUM JDBC differs; compare /tmp/ruby-h2-enum-{java,ruby}.txt'
end
puts "ENUM: #{executions} JDBC executions and ten preparation checks passed (both ordinal bases, typed/text parameters, UTF-16 labels and metadata, conversions, arrays, queries and errors)"

require 'tmpdir'
file_checks = 0
file_java = lambda do |action,path,zero|
  output,error,status = Open3.capture3(java,'-cp',jar,File.join(__dir__,'EnumOracle.java'),action,path,zero.to_s)
  abort "#{error}\n#{output}" unless status.success?
  output
end
labels = (1..20).map { "'e#{it}'" }.join(',')
file_schema = ["CREATE TABLE items(e ENUM(#{labels}) PRIMARY KEY,a ENUM('a','b') ARRAY,u ENUM(U&'\\d800','😀'))",
  "INSERT INTO items VALUES('e1',ARRAY['a','b'],U&'\\d800'),('e15',NULL,'😀'),('e16',ARRAY[],NULL),('e20',ARRAY['b'],U&'\\d800')",
  "CREATE TABLE saved(e ENUM(#{labels}) DEFAULT (SELECT MIN(e) FROM items))",'INSERT INTO saved DEFAULT VALUES']
file_changes = ["DELETE FROM items WHERE e='e1'","UPDATE items SET a=ARRAY[' A '] WHERE e='e15'",
  "INSERT INTO items VALUES('e17',ARRAY['B'],U&'\\d800')",'INSERT INTO saved DEFAULT VALUES']
file_native = lambda do |path,zero,queries,compression|
  H2.connect(path: path,zero_based_enums: zero,compression: compression) do |connection|
    queries.map { render.call(connection.execute(it)) if it.start_with?('SELECT','TABLE') }.compact.join
  end
end
Dir.mktmpdir('h2-enum-reference') do |directory|
  [false,true].product([:none,:fast,:high]).each do |zero,compression|
    java_path = File.join(directory,"java-#{zero}-#{compression}")
    ruby_path = File.join(directory,"ruby-#{zero}-#{compression}")
    file_java.call('create',java_path,zero)
    H2.connect(path: ruby_path,zero_based_enums: zero,compression: compression) { |connection| file_schema.each { connection.execute(it) } }
    queries = ['SELECT e,CAST(e AS INT) AS n,a,u,CAST(u AS INT) AS o FROM items ORDER BY e','TABLE saved ORDER BY e']
    initial = file_java.call('dump',java_path,zero)
    [file_native.call(ruby_path,zero,queries,compression),file_native.call(java_path,zero,queries,compression),file_java.call('dump',ruby_path,zero)].each do |actual|
      abort "ENUM initial file comparison differs: #{zero}/#{compression}\n#{initial}\n#{actual}" unless actual == initial
      file_checks += 1
    end
    H2.connect(path: java_path,zero_based_enums: zero) { |connection| file_changes.each { connection.execute(it) } }
    file_java.call('append',ruby_path,zero)
    updated = file_java.call('dump',java_path,zero)
    [file_native.call(ruby_path,zero,queries,compression),file_native.call(java_path,zero,queries,compression),file_java.call('dump',ruby_path,zero)].each do |actual|
      abort "ENUM cross-write file comparison differs: #{zero}/#{compression}\n#{updated}\n#{actual}" unless actual == updated
      file_checks += 1
    end
  end
end
puts "ENUM: #{file_checks} cross-engine file comparisons passed (both ordinal bases, all compression modes, compact/ENUM tags, UTF-16 labels/metadata, keys, arrays and query defaults)"

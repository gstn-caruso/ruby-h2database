# frozen_string_literal: true

require 'open3'
root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2'

integers = {'TINYINT'=>[-128,-59,-1,0,1,127],'SMALLINT'=>[-32768,-1,0,1,197,32767],
  'INTEGER'=>[-2147483648,-1,0,1,197,2147483647],'BIGINT'=>[-9223372036854775808,-1,0,1,197,9223372036854775807]}
values = ['NULL'] + integers.flat_map { |type, numbers| numbers.map { "CAST(#{it} AS #{type})" } }
binaries = ["X''","X'00'","X'ff'","X'c501'","X'63'","X'80abcd09'","CAST(X'63' AS BINARY)","CAST(X'c501' AS BINARY(2))","CAST(X'c501' AS VARBINARY)"]
valid = values + binaries
invalid = ["'1'",'TRUE','FALSE','1.5','1.5E0','CAST(1 AS REAL)','CAST(1 AS DOUBLE)',"DATE '2000-01-01'",'ARRAY[1]','ROW(1,2)',"JSON '1'"]
offsets = ['NULL','-9223372036854775808','9223372036854775807','-111','-64','-32','-8','-1','0','1','7','8','9','16','31','32','63','64','65','111','1.5',"'1'","'1_0'",'TRUE',"CAST('NaN' AS DOUBLE)"]
statements = []
valid.product(valid,%w[BITAND BITOR BITXOR BITNAND BITNOR BITXNOR]).each do |left,right,name|
  statements << "SELECT #{name}(#{left},#{right}) AS v;"
end
(invalid + valid).each do |value|
  %w[BITNOT BITCOUNT].each do |name|
    statements << "SELECT #{name}(#{value}) AS v;"
    statements << "SELECT #{name}(v) AS v FROM (VALUES(#{value}),(#{value})) t(v);"
  end
  offsets.product(%w[BITGET LSHIFT RSHIFT ULSHIFT URSHIFT ROTATELEFT ROTATERIGHT]).each do |offset,name|
    statements << "SELECT #{name}(#{value},#{offset}) AS v;"
    statements << "SELECT #{name}(v,s) AS v FROM (VALUES(#{value},#{offset}),(#{value},#{offset})) t(v,s);"
  end
end
invalid.product(valid.first(3)+binaries.first(3),%w[BITAND BITOR BITXOR BITNAND BITNOR BITXNOR]).each do |left,right,name|
  statements << "SELECT #{name}(#{left},#{right}) AS v;"
  statements << "SELECT #{name}(#{right},#{left}) AS v;"
end
valid.product(H2::SQL::BitFunctions::AGGREGATES.keys).each do |value,name|
  statements << "SELECT #{name}(v) AS v,#{name}(DISTINCT v) AS d,#{name}(v) FILTER(WHERE FALSE) AS e FROM (VALUES(#{value}),(#{value}),(NULL)) t(v);"
end
%w[BITAND BITOR BITXOR BITNAND BITNOR BITXNOR].each do |name|
  statements << "SELECT #{name}(3,6),#{name}(NULL,1),#{name}(NULL,NULL);"
end
H2::SQL::BitFunctions::ARITIES.each_key do |name|
  ['', '1,2,3','DISTINCT 1'].each { statements << "SELECT #{name}(#{it});" }
end
statements.concat([
  'CREATE TABLE t(a SMALLINT,b SMALLINT,v VARBINARY);',"INSERT INTO t VALUES(3,6,X'c501'),(3,1,X'63'),(NULL,NULL,NULL);",
  'SELECT BITNOT(BITNOT(a)),BITNOT(BITAND(a,b)),BITNOT(BITNAND(a,b)),BITNOT(BITOR(a,b)),BITNOT(BITXOR(a,b)) FROM t;',
  'SELECT BITNOT(BIT_AND_AGG(a)),BITNOT(BIT_NAND_AGG(a)),BITNOT(BIT_XOR_AGG(DISTINCT a)) FILTER(WHERE b>0) FROM t;',
  'SELECT BITNOT(BIT_AND_AGG(a) FILTER(WHERE b>0)),BITNOT(BIT_XOR_AGG(v)) FROM t;',
  'SELECT a,BIT_AND_AGG(b),BIT_OR_AGG(b),BIT_XOR_AGG(b) FROM t GROUP BY a ORDER BY a;',
  'CREATE TABLE saved(v SMALLINT DEFAULT (SELECT BIT_OR_AGG(a) FROM t),b VARBINARY DEFAULT (SELECT BITNOT(BIT_AND_AGG(v)) FROM t));',
  'INSERT INTO saved DEFAULT VALUES;', 'UPDATE t SET a=7 WHERE a=3;', 'INSERT INTO saved DEFAULT VALUES;', 'TABLE saved ORDER BY v;'
])
output,error,status = Open3.capture3(RbConfig.ruby,File.join(__dir__,'compare.rb'),'-',stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Bit functions: #{statements.length} generated Java comparisons passed (widths, binary precision, offsets, nulls, errors, aggregates, filters, simplifications and defaults)"

jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
expected,error,status = Open3.capture3(java,'-cp',jar,File.join(__dir__,'BitFunctionsOracle.java'))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement,*values|
    executions += 1
    result = statement.execute(*values)
    result.types.each_with_index do |type,i|
      precision = type.precision || {'NULL'=>1,'BOOLEAN'=>1,'TINYINT'=>8,'SMALLINT'=>16,'INTEGER'=>32,'BIGINT'=>64,'BINARY'=>1,'VARBINARY'=>1_000_000_000}.fetch(type.name)
      lines << "M\t#{result.columns[i]}\t#{type.name}\t#{precision}\t#{type.scale || 0}"
    end
    result.rows.each do |row|
      text = row.each_with_index.map do |value,i|
        if value.nil? then 'null'
        elsif %w[BINARY VARBINARY].include?(result.types[i].name) then value.unpack1('H*')
        elsif value == true then 'TRUE'
        elsif value == false then 'FALSE'
        else value.to_s
        end
      end
      lines << (['R']+text).join("\t")
    end
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  pairs = [['3','6'],[nil,'bad'],['bad',nil],[nil,nil],[-1,127],[128,1],[32768,-1],[2147483648,1],
    [-9223372036854775808,9223372036854775807],['1_0','2'],[BigDecimal('1.5'),BigDecimal('2.5')],[Float::NAN,0],
    ["\xc5\x01".b,"\x63".b],["\xff".b,"\x00".b],[''.b,"\xff\xff".b]]
  ['TINYINT','SMALLINT','INT','BIGINT','BINARY(2)','VARBINARY(4)'].each do |type|
    %w[BITAND BITOR BITXOR BITNAND BITNOR BITXNOR].each do |name|
      statement = connection.prepare("SELECT #{name}(CAST(? AS #{type}),CAST(? AS #{type})) AS v")
      pairs.each { dump.call(statement,*it) }
    end
    %w[BITGET LSHIFT RSHIFT ULSHIFT URSHIFT ROTATELEFT ROTATERIGHT].each do |name|
      statement = connection.prepare("SELECT #{name}(CAST(? AS #{type}),?) AS v")
      [nil,-1,1,"\xc5\x01".b].product([-1,0,1,7,8,31,32,63,64,65,-9223372036854775808,9223372036854775807,'1_0',Float::NAN]).each { dump.call(statement,*it) }
    end
    %w[BITNOT BITCOUNT].each do |name|
      statement = connection.prepare("SELECT #{name}(CAST(? AS #{type})) AS v")
      [nil,-1,1,'1_0',Float::NAN,"\xff".b,''.b].each { dump.call(statement,it) }
    end
  end
  %w[BITGET BITCOUNT].each do |name|
    statement = connection.prepare("SELECT #{name}(?#{name == 'BITGET' ? ',?' : ''}) AS v")
    [nil,-1,1,2147483648,-9223372036854775808,true,'1',1.5,"\x10\x01".b].each do |value|
      if name == 'BITGET'
        [-1,0,8,64,'bad'].each { dump.call(statement,value,it) }
      else dump.call(statement,value)
      end
    end
  end
  connection.execute('CREATE TABLE source(a TINYINT,b BIGINT,v VARBINARY)')
  connection.execute("INSERT INTO source VALUES(3,6,X'c501'),(3,6,X'c501'),(1,7,X'63'),(NULL,NULL,NULL)")
  H2::SQL::BitFunctions::AGGREGATES.each_key do |name|
    statement = connection.prepare("SELECT #{name}(a) AS a,#{name}(DISTINCT a) FILTER(WHERE b>?) AS d,#{name}(v) AS v FROM source")
    [0,6,7,nil].each { dump.call(statement,it) }
  end
  ['SELECT BITAND(?,1)','SELECT BITNOT(?)','SELECT LSHIFT(?,1)','SELECT BITCOUNT(?)','SELECT BITGET(?,?)',
    "SELECT BITAND(NULL,X'01')","SELECT BITGET('bad',-1)","SELECT BITCOUNT('bad') WHERE FALSE","SELECT LSHIFT('bad',0) WHERE FALSE",
    'SELECT LSHIFT(CAST(? AS INT),?)','SELECT BIT_AND_AGG(?)'].each do |sql|
    begin
      connection.prepare(sql)
      lines << "P\tprepared"
    rescue H2::Error => error
      lines << "P\t#{error.code}\t#{error.sql_state}"
    end
  end
  lines.join("\n") + "\n"
end
if actual != expected
  File.write('/tmp/ruby-h2-bits-java.txt',expected)
  File.write('/tmp/ruby-h2-bits-ruby.txt',actual)
  abort 'Bit JDBC values differ; compare /tmp/ruby-h2-bits-{java,ruby}.txt'
end
puts "Bit functions: #{executions} reused JDBC executions and eleven preparation checks passed (integer/binary metadata, bytes, widths, offsets, null ordering, late-bound inputs, aggregates and filters)"

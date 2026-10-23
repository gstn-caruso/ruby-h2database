# frozen_string_literal: true

require 'open3'

root = File.expand_path('../..',__dir__)
$LOAD_PATH.unshift(File.join(root,'lib'))
require 'h2'
jar = ENV.fetch('H2_REFERENCE_JAR',File.join(root,'h2/target/h2-2.5.259-SNAPSHOT.jar'))
java = ENV['JAVA_HOME'] ? File.join(ENV.fetch('JAVA_HOME'),'bin/java') : 'java'
oracle = [java,'-cp',jar,File.join(__dir__,'FloatingArithmeticOracle.java')]
encode = ->(text) { [text].pack('m0') }
precision = {'NULL'=>1,'BOOLEAN'=>1,'TINYINT'=>8,'SMALLINT'=>16,'INTEGER'=>32,'BIGINT'=>64,
  'NUMERIC'=>100_000,'DECFLOAT'=>100_000,'REAL'=>24,'DOUBLE'=>53,'VARCHAR'=>1_000_000_000}
dump = lambda do |result|
  next "U\t#{result.update_count}\n" unless result.query?

  lines = result.types.each_with_index.map do |type,i|
    name = type.respond_to?(:type_name) ? type.type_name : type.name
    "M\t#{encode.call(result.columns[i])}\t#{encode.call(name)}\t#{type.precision || precision.fetch(type.name)}\t#{type.scale || 0}"
  end
  result.rows.each do |row|
    fields = row.each_with_index.map do |value,i|
      case value
      when nil then 'N'
      when Float
        real = result.types[i].name == 'REAL'
        bits = value.nan? ? (real ? 0x7fc00000 : 0x7ff8000000000000) : [value].pack(real ? 'g' : 'G').unpack1('H*').to_i(16)
        (real ? 'F' : 'D') + bits.to_s(16)
      else
        text = case value
        when BigDecimal then value.frac.zero? ? value.to_i.to_s : value.to_s('F')
        when true then 'TRUE'
        when false then 'FALSE'
        else value.to_s
        end
        'V' + encode.call(text)
      end
    end
    lines << (["R"] + fields).join("\t")
  end
  lines.join("\n") + "\n"
end
run = lambda do |sql|
  dump.call(sql.call)
rescue H2::Error => error
  "E\t#{error.code}\t#{error.sql_state}\n"
end

samples = %w[0 -0.0 0.1 -0.2 1.5 -1.5 16777216 1.4e-45 1.17549435e-38 3.4028235e38 NaN Infinity -Infinity]
statements = []
%w[REAL DOUBLE].each do |type|
  type_samples = type == 'DOUBLE' ? samples + %w[2.2250738585072014e-308 4.9e-324 1.7976931348623157e308 1e-300 -1e300 9007199254740992] : samples
  type_samples.product(type_samples,%w[+ - * / % = <> < > <= >=]).each do |left,right,operator|
    expression = "CAST('#{left}' AS #{type}) #{operator} CAST('#{right}' AS #{type})"
    statements << "SELECT #{expression} AS v;"
    statements << "SELECT a #{operator} b AS v FROM (VALUES(CAST('#{left}' AS #{type}),CAST('#{right}' AS #{type}))) t(a,b);"
  end
  samples.each do |sample|
    value = "CAST('#{sample}' AS #{type})"
    statements << "SELECT -#{value} AS n,ABS(#{value}) AS a,SIGN(#{value}) AS s,CAST(#{value}+#{value} AS DOUBLE) AS d;"
  end
  ['NULL',"'0.5f'","'bad'",'TRUE','CAST(2 AS SMALLINT)','2','CAST(2 AS BIGINT)','CAST(1.5 AS NUMERIC(8,2))','1.5E0'].product(%w[+ - * / %]).each do |other,operator|
    statements << "SELECT CAST('0.285' AS #{type}) #{operator} #{other} AS v;"
    statements << "SELECT #{other} #{operator} CAST('0.285' AS #{type}) AS v;"
  end
  %w[SUM AVG MIN MAX COUNT].each do |name|
    ['', 'DISTINCT '].each do |distinct|
      statements << "SELECT #{name}(#{distinct}v) AS v FROM (VALUES(CAST('0.1' AS #{type})),(CAST('0.2' AS #{type})),(CAST('0.1' AS #{type})),(NULL)) t(v);"
      statements << "SELECT #{name}(#{distinct}v) AS v FROM (VALUES(CAST('NaN' AS #{type})),(CAST('NaN' AS #{type})),(CAST('Infinity' AS #{type})),(CAST('-Infinity' AS #{type})),(NULL)) t(v);"
    end
  end
  statements << "SELECT v,COUNT(*) AS n FROM (VALUES(CAST('NaN' AS #{type})),(CAST('NaN' AS #{type})*CAST(1 AS #{type})),(CAST('Infinity' AS #{type})),(NULL)) t(v) GROUP BY v ORDER BY v;"
  statements << "SELECT DISTINCT v FROM (VALUES(CAST('NaN' AS #{type})),(CAST('NaN' AS #{type})*CAST(1 AS #{type})),(CAST('Infinity' AS #{type})),(NULL)) t(v) ORDER BY v;"
  statements << "SELECT v FROM (VALUES(CAST('NaN' AS #{type})),(CAST('Infinity' AS #{type}))) t(v) UNION SELECT CAST('NaN' AS #{type});"
end
random = Random.new(20261023)
%w[REAL DOUBLE].each do |type|
  25.times do
    left = [random.rand(1 << (type == 'REAL' ? 32 : 64))].pack(type == 'REAL' ? 'N' : 'Q>').unpack1(type == 'REAL' ? 'g' : 'G').to_s
    right = [random.rand(1 << (type == 'REAL' ? 32 : 64))].pack(type == 'REAL' ? 'N' : 'Q>').unpack1(type == 'REAL' ? 'g' : 'G').to_s
    %w[+ - * / %].each do |operator|
      statements << "SELECT CAST('#{left}' AS #{type}) #{operator} CAST('#{right}' AS #{type}) AS v;"
      statements << "SELECT CAST(CAST('#{left}' AS REAL) #{operator} CAST('#{right}' AS REAL) AS DOUBLE) AS v;" if type == 'REAL'
    end
  end
  ['CAST(0.285 AS REAL)',"CAST('NaN' AS REAL)","CAST('Infinity' AS DOUBLE)"].each do |value|
    statements << "SELECT #{value} IN('0.285','NaN') AS i,#{value} BETWEEN '0.285' AND 'NaN' AS b,#{value} IS NOT DISTINCT FROM 'NaN' AS d;"
  end
end
%w[SUM AVG].product(['','DISTINCT ']).each do |name,distinct|
  statements << "SELECT #{name}(#{distinct}v) AS v FROM (VALUES(CAST('1e30' AS REAL)),(CAST('-1e30' AS REAL)),(CAST(1 AS REAL))) t(v);"
end
%w[REAL DOUBLE].product(['NaN','Infinity','0.285'],["'NaN'","'Infinity'","'0.285'",'CAST(0.285 AS NUMERIC(8,3))','CAST(0.285 AS DECFLOAT(8))'],%w[= <> < > <= >=]).each do |type,value,other,operator|
  statements << "SELECT CAST('#{value}' AS #{type}) #{operator} #{other} AS v;"
  statements << "SELECT #{other} #{operator} CAST('#{value}' AS #{type}) AS v;"
end
['REAL','DOUBLE','FLOAT(7)','FLOAT(25)'].each do |type|
  statements << "SELECT CAST(1 AS #{type})+CAST(2 AS #{type}),-CAST(0 AS #{type}),CAST('NaN' AS #{type})*CAST(0 AS #{type});"
end
statements.concat([
  "SELECT ARRAY_CONTAINS(ARRAY[CAST('NaN' AS REAL)],CAST('NaN' AS REAL)) AS v;",
  'SELECT ARRAY_CONTAINS(ARRAY[CAST(0.285 AS REAL)],CAST(0.285 AS NUMERIC(8,3))) AS v;',
  "SELECT ARRAY[CAST('NaN' AS REAL)]=ARRAY[CAST('NaN' AS REAL)] AS v;",
  'SELECT ARRAY[CAST(0.285 AS REAL)]=ARRAY[CAST(0.285 AS NUMERIC(8,3))] AS v;',
  "SELECT CAST(ARRAY_AGG(DISTINCT v ORDER BY v) AS VARCHAR) AS v FROM (VALUES(CAST('NaN' AS REAL)),(CAST('NaN' AS REAL)*CAST(1 AS REAL)),(CAST('Infinity' AS REAL)),(NULL)) t(v);",
  'CREATE TABLE source(a REAL,b REAL);', 'INSERT INTO source VALUES(0.1,0.2);',
  'CREATE TABLE saved(v DOUBLE DEFAULT (SELECT CAST(a+b AS DOUBLE) FROM source),z REAL DEFAULT -CAST(0 AS REAL));',
  'INSERT INTO saved DEFAULT VALUES;', 'UPDATE source SET a=0.3,b=0.4;', 'INSERT INTO saved DEFAULT VALUES;', 'TABLE saved ORDER BY v;',
  "CREATE TABLE floating_keys(v REAL PRIMARY KEY);", "INSERT INTO floating_keys VALUES(CAST('NaN' AS REAL));",
  "INSERT INTO floating_keys VALUES(CAST('NaN' AS REAL)*CAST(1 AS REAL));", 'TABLE floating_keys;'
])
expected,error,status = Open3.capture3(*oracle,stdin_data: statements.map { encode.call(it) }.join("\n") + "\n")
abort error unless status.success?
reference = expected.split("END\n")
abort 'Floating oracle statement count differs' unless reference.length == statements.length
failures = []
H2.connect do |connection|
  statements.zip(reference).each do |sql,wanted|
    actual = run.call(-> { connection.execute(sql) })
    failures << "#{sql}\nJava: #{wanted.inspect}\nRuby: #{actual.inspect}" unless actual == wanted
  end
end
abort failures.first(30).join("\n\n") + "\n#{failures.length} floating comparisons failed" unless failures.empty?
puts "Floating arithmetic: #{statements.length} generated Java comparisons passed (exact IEEE bits, metadata, rounding, specials, mixed types, modulus, predicates, aggregates, grouping, sets and keys)"

expected,error,status = Open3.capture3(*oracle,'prepared')
abort error unless status.success?
pairs = [['0.1','0.2'],['0.3','0.4'],['3.4028235e38','2'],['1.4e-45','2'],['NaN','0'],['NaN','2'],['Infinity','-Infinity'],
  [nil,'bad'],['bad',nil],[nil,'0'],['1','0.5f'],['1','bad'],[0.1,0.2],[Float::NAN,Float::NAN],[Float::INFINITY,0],
  [BigDecimal('1.0000000596046448'),BigDecimal('0.1')]]
executions = 0
actual = H2.connect do |connection|
  sql = ['REAL','DOUBLE','FLOAT(7)','FLOAT(25)'].product(%w[+ - * / %]).map { |type,op| "SELECT CAST(? AS #{type}) #{op} CAST(? AS #{type}) AS v" }
  sql.concat(['SELECT CAST(? AS REAL)+CAST(? AS VARCHAR) AS v','SELECT CAST(? AS VARCHAR)+(CAST(? AS REAL)/CAST(0 AS REAL)) AS v',
    'SELECT MOD(CAST(? AS REAL),CAST(? AS VARCHAR)) AS v'])
  results = sql.map do |query|
    statement = connection.prepare(query)
    pairs.map do |values|
      executions += 1
      run.call(-> { statement.execute(*values) }) + "END\n"
    end.join
  end.join
  ['SELECT CAST(1 AS REAL)/CAST(0 AS REAL) WHERE FALSE',"SELECT CAST('NaN' AS REAL)%CAST(0 AS REAL) WHERE FALSE",
    "SELECT MOD(CAST(? AS REAL),'bad')",'SELECT MOD(?,?)','SELECT CAST(? AS REAL)+?',"SELECT CAST(NULL AS REAL)+'bad'",
    "SELECT MOD(CAST(NULL AS REAL),'bad')",'SELECT CAST(? AS REAL)+CAST(? AS VARCHAR)',"SELECT MOD('1','2')",'SELECT MOD(NULL,NULL)'].each do |query|
    begin
      connection.prepare(query)
      results += "P\tprepared\nEND\n"
    rescue H2::Error => error
      results += "P\t#{error.code}\t#{error.sql_state}\nEND\n"
    end
  end
  results
end
if expected != actual
  File.write('/tmp/ruby-h2-floating-java.txt',expected)
  File.write('/tmp/ruby-h2-floating-ruby.txt',actual)
  abort 'Floating JDBC values differ; compare /tmp/ruby-h2-floating-{java,ruby}.txt'
end
puts "Floating arithmetic: #{executions} reused JDBC executions and ten preparation checks passed (typed parameters, conversion order, nulls, errors and exact bits)"

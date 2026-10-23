# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
probe, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "NumericConversionOracle.java"), "floating-format")
abort error unless status.success?
version, *formats = probe.lines.map(&:chomp)
legacy_format = case formats
when ["F\t2.1474836E9", "D\t3.402823669209385E38"] then false
when ["F\t2.14748365E9", "D\t3.4028236692093846E38"] then true
else abort "Unexpected Java floating-point format: #{probe}"
end

values = ['NULL','TRUE','FALSE','0','127','128','-129','32768','2147483648','9223372036854775807','9223372036854775808',
  '1.5','-1.5',"CAST('9223372036854775807.1' AS NUMERIC(20,1))",'1E100','1E-100',
  "CAST('NaN' AS DECFLOAT)","CAST('Infinity' AS DECFLOAT)","CAST('-Infinity' AS DECFLOAT)",
  "CAST('NaN' AS REAL)","CAST('Infinity' AS DOUBLE)","CAST('-Infinity' AS REAL)",
  'CAST(0.285 AS REAL)','CAST(1.2 AS NUMERIC(8,2))',"X'00000001'", "UUID '00000000-0000-0000-0000-000000000001'"]
texts = ['',' ','1','-1.5',' +127 ','2147483648','9223372036854775808','1_0','0x10','0x1.8p1','0x.8p-1','0x1p128',
  '0.5f','0.5D','NaN','+NaN','-NaN','Infinity','+Infinity','-Infinity','nan','Inf','NaNf',
  '１２٣','-١٢','１２.٣٤','1e٢','𝟙','1.0000000596046448','7.006492321624086e-46','3.4028235677973367e38',
  'true','FALSE','yes','n','0.0',"\u00a01\u00a0","\u000b1\u000b",'1e2147483649','0x1p9999999999','0x1p-9999999999']
values += texts.map { "'#{it.gsub("'", "''")}'" }
types = ['TINYINT','SMALLINT','INT','BIGINT','NUMERIC','NUMERIC(8,2)','DECIMAL(8,2)','DEC(1,3)','NUMBER','NUMBER(6,2)',
  'DECFLOAT(8)','REAL','DOUBLE','FLOAT','FLOAT(7)','FLOAT(25)','BOOLEAN','VARCHAR']
statements = []
format_statements = []
values.product(types).each do |value,type|
  separate = legacy_format && ((['2147483648',"'2147483648'"].include?(value) && ['REAL','FLOAT(7)'].include?(type)) ||
    (value == "'0x1p128'" && ['DOUBLE','FLOAT','FLOAT(25)'].include?(type)))
  destination = separate ? format_statements : statements
  destination << "SELECT CAST(#{value} AS #{type});"
  destination << "SELECT CAST(v AS #{type}) AS v FROM (VALUES(#{value}),(#{value})) t(v);"
end
['NUMERIC','DECIMAL','NUMBER','FLOAT'].product(['','0','-1','+2','2.5',"'2'",'NULL','100000','100001','2147483648']).each do |type,argument|
  statements << "SELECT CAST(NULL AS #{type}(#{argument}));"
end
['NUMERIC','DEC','NUMBER'].product(['2,-1','2,100001','2,0','2,1.5','2,2147483648','100000','2,3']).each do |type,arguments|
  statements << "SELECT CAST(NULL AS #{type}(#{arguments}));"
end
%w[NUMERIC DECIMAL FLOAT].product(['','(8,2)','(7)','(25)']).each do |type,arguments|
  statements << "CREATE TABLE t#{statements.length}(v #{type}#{arguments});"
end
statements.concat([
  "SELECT CAST(1.2 AS DECIMAL(8,2)) AS n UNION ALL SELECT NULL;",
  "SELECT CAST(1.2 AS DECIMAL(8,2)) AS n UNION ALL SELECT CAST(1.2 AS DECIMAL(8,2));",
  "SELECT CAST(1.2 AS FLOAT(7)) AS n UNION ALL SELECT NULL;",
  "SELECT ROUND(CAST(1.20 AS DECIMAL(8,2)),2);",
  "SELECT FLOOR(CAST(1 AS DECIMAL(8,0)));",
  "SELECT COALESCE(NULL,CAST(1.2 AS DECIMAL(8,2)));",
  "SELECT CASE WHEN TRUE THEN CAST(1.2 AS DECIMAL(8,2)) ELSE NULL END;",
  "SELECT CAST(NULL AS NUMERIC(1e1)),CAST(NULL AS FLOAT(1e1));",
  "SELECT CAST(NULL AS NUMERIC(-1e1));",
  "SELECT CAST(NULL AS NUMERIC(-'2'));",
  "SELECT CAST(NULL AS NUMERIC(+'2'));"
])
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Numeric conversions: #{statements.length} generated Java comparisons passed (aliases, declarations, text syntax, Unicode, bounds, nulls, specials and rounding)"

unless format_statements.empty?
  H2.connect do |connection|
    format_statements.each do |sql|
      real = sql.include?(' AS REAL)') || sql.include?(' AS FLOAT(7))')
      expected_value = Math.ldexp(1.0, real ? 31 : 128)
      expected_label = real ? '2.1474836E9' : '3.402823669209385E38'
      result = connection.execute(sql)
      labels = [sql.include?(' AS v FROM ') ? 'V' : expected_label]
      abort "Native floating-point format differs: #{sql}" unless result.columns == labels &&
        result.types.first.name == (real ? 'REAL' : 'DOUBLE') && result.rows.all? { it == [expected_value] }
    end
  end
  puts "Numeric conversion runtime difference: Java #{version.delete_prefix("J\t")} uses legacy float text; #{format_statements.length} native cases pass separately against independent power-of-two values/modern labels, not counted as Java matches"
end

expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "NumericConversionOracle.java"))
abort error unless status.success?
executions = 0
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, value|
    executions += 1
    result = statement.execute(value)
    type = result.types.first
    precision = type.precision || {"REAL" => 24, "DOUBLE" => 53, "TINYINT" => 8, "SMALLINT" => 16,
      "INTEGER" => 32, "BIGINT" => 64, "BOOLEAN" => 1, "VARCHAR" => 1_000_000_000}.fetch(type.name)
    lines << "M\t#{result.columns.first}\t#{type.type_name}\t#{precision}\t#{type.scale || 0}"
    result.rows.each do |row|
      item = row.first
      text = case item
      when nil then 'null'
      when Float
        bits = item.nan? ? (type.name == 'REAL' ? 0x7fc00000 : 0x7ff8000000000000) : [item].pack(type.name == 'REAL' ? 'g' : 'G').unpack1('H*').to_i(16)
        bits.to_s(16)
      when BigDecimal then H2::ArrayType.decimal_text(item,type.scale)
      when true then 'TRUE'
      when false then 'FALSE'
      else item.to_s
      end
      lines << "R\t#{text}"
    end
  rescue H2::Error => exception
    lines << "E\t#{exception.code}\t#{exception.sql_state}"
  end
  parameters = [nil,true,false,1,-128,128,2147483648,9223372036854775807,
    BigDecimal('1.0000000596046448'),BigDecimal('9223372036854775807.1'),0.285,Float::NAN,Float::INFINITY,-Float::INFINITY,
    '1.0000000596046448','7.006492321624086e-46','3.4028235677973367e38',
    '0x1.00000100000000000001p0','0x0.000000000000000000001p-65','1_0','128','１２٣','１２.٣٤','0.5f','true','NaN',"\x00\x00\x00\x01".b,'2147483648','0x1p128']
  ['TINYINT','SMALLINT','INT','BIGINT','NUMERIC(8,2)','DECIMAL(8,2)','NUMBER','NUMBER(6,2)',
    'DECFLOAT(8)','REAL','DOUBLE','FLOAT(7)','FLOAT(25)','BOOLEAN','VARCHAR'].each do |type|
    statement = connection.prepare("SELECT CAST(? AS #{type}) AS v")
    parameters.each { dump.call(statement,it) }
  end
  ['REAL','DOUBLE','DECFLOAT','NUMERIC(30,20)'].product(['NUMERIC(8,2)','REAL','DOUBLE','BOOLEAN','VARCHAR']).each do |source,type|
    statement = connection.prepare("SELECT CAST(CAST(? AS #{source}) AS #{type}) AS v")
    ['0.285','1.0000000596046448','NaN','Infinity',nil].each { dump.call(statement,it) }
  end
  ["SELECT CAST('1_0' AS INT) WHERE FALSE","SELECT CAST('128' AS TINYINT) WHERE FALSE",
    "SELECT CAST(NULL AS FLOAT(54))","SELECT CAST(NULL AS NUMERIC(100001))","SELECT CAST(NULL AS NUMERIC(2,-1))"].each do |sql|
    begin
      connection.prepare(sql)
      lines << "P\tprepared"
    rescue H2::Error => exception
      lines << "P\t#{exception.code}\t#{exception.sql_state}"
    end
  end
  lines.join("\n") + "\n"
end
if actual != expected
  File.write('/tmp/ruby-h2-numeric-conversion-java.txt',expected)
  File.write('/tmp/ruby-h2-numeric-conversion-ruby.txt',actual)
  abort 'Numeric conversion JDBC values differ; compare /tmp/ruby-h2-numeric-conversion-{java,ruby}.txt'
end
puts "Numeric conversions: #{executions} JDBC executions and five preparation checks passed (metadata, typed parameters, Unicode, binary values and exact IEEE 754 bits)"

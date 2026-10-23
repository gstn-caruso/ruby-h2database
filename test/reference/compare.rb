# frozen_string_literal: true

require "json"
require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first: mvn -f h2/pom.xml -DskipTests package" unless File.file?(jar)

java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
fixture = ARGV.first || File.join(root, "test/fixtures/relational_reference.sql")
statements = File.readlines(fixture).map(&:strip).reject { it.empty? || it.start_with?("--") }
decode = ->(text) { text.unpack1("m0").force_encoding(Encoding::UTF_8) }
input = statements.map { [it].pack("m0") }.join("\n") + "\n"
output, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "JdbcOracle.java"), stdin_data: input)
abort error unless status.success?
reference = output.split("END\n").map { it.lines.map(&:chomp) }
abort "Java reference returned #{reference.length} results for #{statements.length} statements" unless reference.length == statements.length

type_names = {"CHARACTER VARYING" => "VARCHAR", "CHARACTER" => "CHAR", "DOUBLE PRECISION" => "DOUBLE", "BINARY VARYING" => "VARBINARY"}
normalize = lambda do |value, type|
  next nil if value.nil?

  if %w[BINARY VARBINARY].include?(type)
    value.unpack1("H*")
  elsif %w[TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE].include?(type)
    BigDecimal(value.to_s).to_s("F")
  elsif value == true || value == false
    value ? "TRUE" : "FALSE"
  else
    value.to_s
  end
end

failures = []
H2.connect do |connection|
  statements.zip(reference).each_with_index do |(sql, lines), index|
    parts = lines.first.split("\t")
    expected = case parts.first
    when "U" then {update_count: parts[1].to_i}
    when "E" then {error: parts[1].to_i, state: parts[2]}
    when "Q"
      columns = parts.drop(1).map { decode.call(it) }
      types = lines[1].split("\t").drop(1).map do |encoded|
        type = decode.call(encoded)
        type.start_with?("ROW(") ? "ROW" : type_names.fetch(type, type)
      end
      rows = lines.drop(2).map do |line|
        line.split("\t").drop(1).each_with_index.map do |value, column|
          normalize.call(value == "N" ? nil : decode.call(value[1..]), types[column])
        end
      end
      rows = rows.sort_by { JSON.generate(it) } unless sql.match?(/\bORDER\s+BY\b/i)
      {columns: columns, types: types, rows: rows}
    else abort "Unknown reference response: #{lines.inspect}"
    end

    actual = begin
      result = connection.execute(sql)
      if result.query?
        types = result.types.map(&:name)
        rows = result.rows.map { |row| row.each_with_index.map { |value, column| normalize.call(value, types[column]) } }
        rows = rows.sort_by { JSON.generate(it) } unless sql.match?(/\bORDER\s+BY\b/i)
        {columns: result.columns, types: types, rows: rows}
      else
        {update_count: result.update_count}
      end
    rescue H2::Error => exception
      {error: exception.code, state: exception.sql_state}
    end
    next if expected == actual

    failures << "#{fixture}:#{index + 1}\n#{sql}\nJava: #{expected.inspect}\nRuby: #{actual.inspect}"
  end
end
abort failures.join("\n\n") unless failures.empty?

puts "#{statements.length} statements match the Java reference (results, labels, type names, update counts, errors and SQL states)"

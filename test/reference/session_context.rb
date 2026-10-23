# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "SessionClockOracle.java"))
abort error unless status.success?
database = H2::Database.new
actual = database.connect do |connection|
  lines = []
  metadata = lambda do |sql|
    result = connection.execute(sql)
    result.types.each_with_index { |type, index| lines << "M\t#{result.columns[index]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
  end
  metadata.call("SELECT CURRENT_DATE(),LOCALTIME,LOCALTIMESTAMP,CURDATE(),CURTIME(),NOW()")
  (0..9).each { |scale| metadata.call("SELECT LOCALTIME(#{scale}),LOCALTIMESTAMP(#{scale}),CURTIME(#{scale}),NOW(#{scale})") }
  statement = connection.prepare("SELECT LOCALTIMESTAMP(9)")
  clock = -> { statement.execute.rows.first.first }
  first = clock.call
  sleep 0.005
  lines << "C\tautocommit refresh\t#{first != clock.call}"
  connection.execute("SET AUTOCOMMIT FALSE")
  first = clock.call
  sleep 0.005
  lines << "C\ttransaction snapshot\t#{first == clock.call}"
  database.connect { |other| lines << "C\tindependent connection\t#{first != other.execute('SELECT LOCALTIMESTAMP(9)').rows.first.first}" }
  connection.execute("SAVEPOINT keep_clock")
  lines << "C\tsavepoint keeps clock\t#{first == clock.call}"
  connection.execute("ROLLBACK TO SAVEPOINT keep_clock")
  lines << "C\trollback to savepoint refresh\t#{first != clock.call}"
  first = clock.call
  sleep 0.005
  errors = lambda do |sql|
    connection.execute(sql)
  rescue H2::Error => error
    lines << "E\t#{error.code}\t#{error.sql_state}"
  end
  errors.call("SELECT 1/0")
  lines << "C\tfailed statement keeps clock\t#{first == clock.call}"
  errors.call("ROLLBACK TO SAVEPOINT missing")
  lines << "C\tfailed rollback refresh\t#{first != clock.call}"
  first = clock.call
  sleep 0.005
  connection.execute("CREATE TABLE reset_clock(v INT)")
  lines << "C\tDDL refresh\t#{first != clock.call}"
  first = clock.call
  sleep 0.005
  connection.commit
  lines << "C\tcommit refresh\t#{first != clock.call}"
  first = clock.call
  sleep 0.005
  connection.rollback
  lines << "C\trollback refresh\t#{first != clock.call}"
  cast = connection.prepare("SELECT CAST(? AS TIMESTAMP(9))=CAST(CURRENT_DATE AS TIMESTAMP)+CAST(? AS TIME(9)) AS v")
  [H2::TimeValue.new(0), H2::TimeValue.parse("12:34:56.123456789"), H2::TimeValue.new(H2::Temporal::DAY - 1), nil].each do |value|
    result = cast.execute(value, value).rows.first.first
    lines << "P\t#{result.nil? ? 'null' : result.to_s.upcase}"
  end
  lines.join("\n") + "\n"
end
database.close
abort "Session JDBC behavior differs:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Session clock: 46 JDBC metadata fields, 10 lifecycle checks, errors and 4 reused LocalTime parameter bindings match Java"

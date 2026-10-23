# frozen_string_literal: true

require "open3"
require "json"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
expected, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "ZonedTemporalOracle.java"))
abort error unless status.success?
data, transcript = expected.lines.partition { it.start_with?("D\t", "Z\t") }
expected = transcript.join
java_version = data.find { it.start_with?("D\t") }.split("\t").last.strip
java_offsets = data.select { it.start_with?("Z\t") }.to_h do |line|
  _tag, year, month, offset = line.strip.split("\t")
  [[year.to_i, month.to_i], offset.to_i]
end
system_version = File.foreach(File.join(H2::TimeZone::ROOT, "tzdata.zi")).first.split.last
profiles = java_offsets.keys
system_output, error, status = Open3.capture3({"TZ" => "Africa/Casablanca"}, RbConfig.ruby, "-rjson", "-e",
  'puts JSON.generate(JSON.parse(STDIN.read).map { |year, month| Time.local(year, month, 15, 12, 34, 56).utc_offset })', stdin_data: JSON.generate(profiles))
abort error unless status.success?
system_offsets = profiles.zip(JSON.parse(system_output)).to_h
data_differences = java_offsets.keys.select { java_offsets[it] != system_offsets.fetch(it) }
unless data_differences.empty?
  data_differences.each do |profile|
    a, b = [java_offsets.fetch(profile), system_offsets.fetch(profile)]
    changed_version = a.zero? ? java_version : system_version
    unless [a, b].sort == [0, 3600] && changed_version >= "2026e"
      abort "Unexpected Casablanca tzdb difference: system #{system_version} / Java #{java_version}, #{profile.inspect}: #{b} / #{a}"
    end
  end
end
actual = H2.connect do |connection|
  lines = []
  dump = lambda do |statement, *values|
    result = statement.execute(*values)
    result.types.each_with_index { |type, i| lines << "M\t#{result.columns[i]}\t#{type.name}\t#{type.precision}\t#{type.scale}" }
    result.rows.each { |row| lines << (["R"] + row.map { it.nil? ? "null" : it.to_s }).join("\t") }
  end
  connection.execute("SET TIME ZONE '+03'")
  dump.call(connection.prepare("SELECT CURRENT_TIME AS t,CURRENT_TIMESTAMP AS ts WHERE FALSE"))
  time = H2::TimeTimeZoneValue.parse("23:59:59.999999999-03:30:15")
  timestamp = H2::TimestampTimeZoneValue.parse("2000-02-28 23:59:59.999999999+03")
  [0, 1, 3, 6, 9].each do |scale|
    statement = connection.prepare("SELECT CAST(? AS TIME(#{scale}) WITH TIME ZONE) AS t,CAST(? AS TIMESTAMP(#{scale}) WITH TIME ZONE) AS ts")
    dump.call(statement, time, timestamp)
    dump.call(statement, nil, nil)
  end
  dump.call(connection.prepare("SELECT CAST(? AS TIME(9)) AS t,CAST(? AS TIMESTAMP(9)) AS ts,CAST(? AS DATE) AS d"), time, timestamp, timestamp)
  statement = connection.prepare("SELECT TIMESTAMP WITH TIME ZONE '2000-01-01 12:00:00' AS l,CAST('2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE) AS c,CAST(? AS TIMESTAMP WITH TIME ZONE) AS p,EXTRACT(timezone_hour FROM DATE '2000-01-01') AS h")
  connection.execute("SET TIME ZONE '-05'")
  dump.call(statement, "2000-01-01 12:00:00")
  statement = connection.prepare("SELECT CAST(? AS TIMESTAMP(9) WITH TIME ZONE) AT TIME ZONE ? AS v")
  ["UTC", "America/New_York", nil].each { dump.call(statement, timestamp, it) }
  connection.execute("SET TIME ZONE '+03'")
  connection.execute("CREATE TABLE defaults(frozen TIMESTAMP WITH TIME ZONE DEFAULT CAST('2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE),variable TIMESTAMP WITH TIME ZONE DEFAULT CAST(TIMESTAMP '2000-01-01 12:00:00' AS TIMESTAMP WITH TIME ZONE),coalesced TIME WITH TIME ZONE DEFAULT COALESCE(TIME '12:00:00',TIME WITH TIME ZONE '12:00:00Z'))")
  connection.execute("CREATE TABLE bound(t TIME WITH TIME ZONE DEFAULT CAST(? AS TIME WITH TIME ZONE))", "12:00:00")
  connection.execute("SET TIME ZONE '-05'")
  connection.execute("INSERT INTO defaults DEFAULT VALUES")
  connection.execute("INSERT INTO bound DEFAULT VALUES")
  dump.call(connection.prepare("SELECT * FROM defaults"))
  dump.call(connection.prepare("TABLE bound"))
  connection.execute("SET TIME ZONE 'UTC'")
  connection.execute("SET AUTOCOMMIT FALSE")
  connection.prepare("SELECT CAST(TIME '12:00:00' AS TIMESTAMP)")
  boundary = (Time.now.to_r * 1000).floor
  sleep 0.01
  captured = connection.execute("SELECT CURRENT_TIMESTAMP(9)").rows.first.first.epoch_nanos.div(1_000_000)
  lines << "C\tcast preparation captures clock\t#{captured <= boundary}"
  lines.join("\n") + "\n"
end
abort "Zoned JDBC values differ:\nJava:\n#{expected}\nRuby:\n#{actual}" unless actual == expected
puts "Zoned temporal values: 18 JDBC comparisons passed (offset bindings, nulls, scales, zone conversion, preparation, saved defaults and clock capture)"

statements = ["SET TIME ZONE 'UTC';"]
independent_cases = []
offsets = ["-18", "-12:34:56", "-00:00:01", "Z", "+00:00:01", "+05:30", "+18", "+12:99"]
times = ["00:00:00", "12:34:56.123456789", "23:59:59.999999999"]
offsets.product(times, [0, 1, 3, 6, 9]).each do |offset, time, scale|
  t = "TIME WITH TIME ZONE '#{time}#{offset}'"
  ts = "TIMESTAMP WITH TIME ZONE '2000-02-28 #{time}#{offset}'"
  statements << "SELECT CAST(#{t} AS TIME(#{scale}) WITH TIME ZONE) AS t,CAST(#{ts} AS TIMESTAMP(#{scale}) WITH TIME ZONE) AS ts,EXTRACT(epoch FROM #{t}) AS epoch,EXTRACT(timezone_second FROM #{t}) AS s;"
end
zones = %w[UTC Europe/Paris America/New_York Australia/Lord_Howe Asia/Kathmandu America/Argentina/Buenos_Aires Europe/Dublin Africa/Casablanca Pacific/Apia]
zones.each do |zone|
  statements << "SET TIME ZONE '#{zone}';"
  [-1_000_000_000, -999_999_999, -400, 0, 1, 1582, 1900, 1970, 2000, 2024, 2400, 1_000_000_000].product([1, 7]).each do |year, month|
    text = "#{year.negative? ? '-' : ''}#{year.abs.to_s.rjust(4, '0')}-#{month.to_s.rjust(2, '0')}-15 12:34:56.123456789"
    value = "TIMESTAMP WITH TIME ZONE '#{text} #{zone}'"
    sql = "SELECT #{value} AS ts,CAST(#{value} AS TIMESTAMP(9)) AS local_time,EXTRACT(timezone_second FROM #{value}) AS seconds;"
    if zone == "Africa/Casablanca" && data_differences.include?([year, month])
      independent_cases << [sql, year, month]
    else
      statements << sql
    end
  end
end
%w[Europe/Paris America/New_York Australia/Lord_Howe Europe/Dublin].each do |zone|
  statements << "SET TIME ZONE '#{zone}';"
  [1900, 1970, 2000, 2023, 2024, 2038, 2100, 2400].product([3, 4, 10, 11], [1, 3, 7, 10, 27, 31], %w[00:30:00 01:30:00 02:30:00 03:30:00]).each do |year, month, day, time|
    text = "#{year}-#{month.to_s.rjust(2, '0')}-#{day.to_s.rjust(2, '0')} #{time}"
    statements << "SELECT TIMESTAMP WITH TIME ZONE '#{text} #{zone}' AS literal,CAST(TIMESTAMP '#{text}' AS TIMESTAMP(9) WITH TIME ZONE) AS converted,TIMESTAMP '#{text} #{zone}' AS local_text;"
  end
end
statements << "SET TIME ZONE 'Pacific/Apia';"
[29, 30, 31].product(%w[00:00:00 12:00:00 23:00:00]).each do |day, time|
  text = "2011-12-#{day} #{time}"
  statements << "SELECT TIMESTAMP WITH TIME ZONE '#{text} Pacific/Apia' AS literal,CAST(TIMESTAMP '#{text}' AS TIMESTAMP(9) WITH TIME ZONE) AS converted,TIMESTAMP '#{text} Pacific/Apia' AS local_text;"
end
values = ["DATE '2000-01-01'", "TIME '12:34:56.123456789'", "TIME WITH TIME ZONE '12:34:56.123456789-03:30:15'",
  "TIMESTAMP '2000-01-01 12:34:56.123456789'", "TIMESTAMP WITH TIME ZONE '2000-01-01 12:34:56.123456789+05:30'"]
%w[UTC +03 -05 Europe/Paris].each do |zone|
  statements << "SET TIME ZONE '#{zone}';"
  values.product(H2::Temporal::NAMES).each { |value, type| statements << "SELECT CAST(#{value} AS #{type}) AS v;" }
  values.product(values, %w[+ - * /]).each { |a, b, operator| statements << "SELECT #{a}#{operator}#{b} AS v;" }
  values.product(%w[+ - * /], ["1", "CAST(1 AS BIGINT)", "0.5", "CAST(2 AS DOUBLE)"]).each do |value, operator, number|
    statements << "SELECT #{value}#{operator}#{number} AS v;"
    statements << "SELECT #{number}#{operator}#{value} AS v;"
  end
  values.each do |value|
    %w[TIMEZONE_HOUR TIMEZONE_MINUTE TIMEZONE_SECOND].each do |field|
      statements << "SELECT EXTRACT(#{field} FROM #{value}) AS v,DATEADD(#{field},1,#{value}) AS added,DATEDIFF(#{field},DATE '2000-01-01',#{value}) AS difference;"
    end
  end
end
output, error, status = Open3.capture3(RbConfig.ruby, File.join(__dir__, "compare.rb"), "-", stdin_data: statements.join("\n"))
abort "#{output}\n#{error}" unless status.success?
puts "Zoned temporal values: #{statements.length} generated Java comparisons passed (offsets, rounding, year bounds, IANA history/future, DST gaps/overlaps, casts, arithmetic and timezone fields)"
unless independent_cases.empty?
  H2.connect do |connection|
    connection.execute("SET TIME ZONE 'Africa/Casablanca'")
    independent_cases.each do |sql, year, month|
      result = connection.execute(sql)
      value, local, seconds = result.rows.first
      offset = system_offsets.fetch([year, month])
      expected_date = H2::DateValue.new(year, month, 15)
      expected_time = H2::TimeValue.parse("12:34:56.123456789")
      unless value.date == expected_date && value.time == expected_time && value.offset_seconds == offset &&
          local == H2::TimestampValue.new(expected_date, expected_time) && seconds == offset.remainder(60) &&
          result.types.map(&:name) == ["TIMESTAMP WITH TIME ZONE", "TIMESTAMP", "INTEGER"]
        abort "Native Casablanca SQL differs from independent system timezone data: #{sql}"
      end
    end
  end
  puts "Timezone data difference: #{independent_cases.length} Casablanca future cases use system tzdb #{system_version}, differing from Java #{java_version}; native values/casts match the independent system clock (IANA 2026e change)"
end

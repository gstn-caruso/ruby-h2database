# frozen_string_literal: true

require "open3"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2"
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first" unless File.file?(jar)
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
bytes = +"".b
256.times { |a| 256.times { |b| bytes << [a, b, 0].pack("C*") } }
[0xe0, 0xed, 0xef, 0xf0, 0xf4].each do |lead|
  [0, 0x7f, 0x80, 0x8f, 0x90, 0x9f, 0xa0, 0xbf, 0xc0, 0xff].repeated_permutation(3) do |rest|
    bytes << [lead, *rest, 0].pack("C*")
  end
end
sql = "SELECT CAST(X'#{bytes.unpack1('H*')}' AS VARCHAR) AS decoded"
output, error, status = Open3.capture3(java, "-cp", jar, File.join(__dir__, "JdbcOracle.java"), stdin_data: [sql].pack("m0") + "\n")
abort error unless status.success?
row = output.lines.find { it.start_with?("R\tV") }
abort "Missing Java UTF-8 result" unless row
expected = row.chomp.delete_prefix("R\tV").unpack1("m0").force_encoding(Encoding::UTF_8)
actual = H2.connect { |connection| connection.execute(sql).rows.first.first }
abort "Binary-to-text UTF-8 decoding differs" unless actual == expected

puts "Binary-to-text UTF-8 matches Java for all 65,536 byte pairs and 5,000 multibyte boundary sequences"

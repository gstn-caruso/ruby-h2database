# frozen_string_literal: true

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2/mvstore"

jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first: mvn -f h2/pom.xml -DskipTests package" unless File.file?(jar)

java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
command = [java, "-cp", jar, File.join(__dir__, "MVStoreOracle.java")]
run = lambda do |*arguments|
  output, error, status = Open3.capture3(*command, *arguments)
  abort error unless status.success?
  output
end
decode = lambda do |hex|
  text = [hex].pack("H*").force_encoding(Encoding::UTF_16BE)
  text.valid_encoding? ? text.encode(Encoding::UTF_8) : text
end
dump = lambda do |path|
  maps = [{}, {}]
  run.call("dump", path).each_line do |line|
    kind, key, value = line.chomp.split("\t", -1)
    case kind
    when "S" then maps[0][decode.call(key)] = decode.call(value)
    when "L" then maps[1][key.to_i] = value.to_i
    else abort "Unknown MVStore oracle result #{kind}"
    end
  end
  maps
end
words_name = 'words, "Unicode"'
read_native = lambda do |path|
  H2::MVStore::Store.open(path, read_only: true) do |store|
    [store.open_map(words_name).to_h, store.open_map("longs", key_type: :long, value_type: :long).to_h]
  end
end
checks = 0
assert = lambda do |condition, message|
  abort message unless condition
  checks += 1
end

Dir.mktmpdir("ruby-mvstore-reference-") do |directory|
  [:none, :fast, :high].each_with_index do |compression, level|
    path = File.join(directory, "java-#{level}.mv")
    run.call("create", path, level.to_s)
    expected = dump.call(path)
    assert.call(expected == read_native.call(path), "Cannot read Java #{compression} MVStore")
    H2::MVStore::Store.open(path, compression: compression, keys_per_page: 8) do |store|
      words = store.open_map(words_name)
      words["ruby"] = "native payload 😀"
      words.delete("key-002")
      expected[0]["ruby"] = "native payload 😀"
      expected[0].delete("key-002")
      store.commit
    end
    assert.call(expected == dump.call(path), "Java cannot read Ruby commit or preserved unopened map (#{compression})")
    run.call("mutate", path)
    expected[0]["java"] = "after ruby"
    expected[0].delete("key-003")
    expected[1][9] = -9
    assert.call(expected == read_native.call(path), "Ruby cannot read later Java commit (#{compression})")

    path = File.join(directory, "ruby-#{level}.mv")
    expected = [{}, {}]
    H2::MVStore::Store.open(path, compression: compression, keys_per_page: 8) do |store|
      words = store.open_map(words_name)
      160.times { |index| expected[0]["key-#{index}"] = "record #{index} " + "unicode 中文 😀" * 30 }
      expected[0]["large"] = "abcd😀" * 160_000 if compression == :none
      expected[0][decode.call("d800")] = decode.call("dfff")
      expected[0].each { |key, value| words[key] = value }
      longs = store.open_map("longs", key_type: :long, value_type: :long)
      [-(1 << 63), -7, 0, 1, (1 << 63) - 1].each { |key| expected[1][key] = ~key; longs[key] = ~key }
      store.commit
      words["ruby"] = "second commit"
      expected[0]["ruby"] = "second commit"
    end
    assert.call(expected == dump.call(path), "Java cannot read native file, node pages, large pages or UTF-16 (#{compression})")
    assert.call(expected == read_native.call(path), "Native reopen mismatch (#{compression})")
  end

  path = File.join(directory, "ruby-0.mv")
  H2::MVStore::Store.open(path) do
    assert.call(run.call("lock", path).strip == "ERROR 7", "Java did not respect Ruby's OFD lock")
  end
  Open3.popen3(*command, "lock", path) do |input, output, error, wait|
    assert.call(output.gets&.strip == "LOCKED", "Java lock process did not acquire the file")
    begin
      H2::MVStore::Store.open(path)
      abort "Ruby did not respect Java's lock"
    rescue H2::MVStore::Error => exception
      assert.call(exception.code == 7, "Unexpected Ruby lock error #{exception.code}")
    ensure
      input.puts "release"
      input.close
    end
    assert.call(wait.value.success?, "Java lock process did not exit cleanly")
  end
  child = <<~'RUBY'
    require "h2/mvstore"
    store = H2::MVStore::Store.open(ARGV.fetch(0))
    store.open_map('words, "Unicode"')["crash"] = "committed before exit"
    store.commit
    Process.kill(:KILL, Process.pid)
  RUBY
  _output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", child, path)
  assert.call(status.signaled? && status.termsig == 9, "Crash process did not reach committed state: #{error}")
  expected = dump.call(path)
  assert.call(expected[0]["crash"] == "committed before exit", "Java did not recover committed data after process death")
  assert.call(expected == read_native.call(path), "Ruby and Java recovery disagree")
end

puts "MVStore: #{checks} cross-engine checks passed (files, commits, compression, B-trees, UTF-16, locks and process death)"

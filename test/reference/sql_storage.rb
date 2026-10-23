# frozen_string_literal: true

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2/mvstore"

storage = H2::MVStore
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first: mvn -f h2/pom.xml -DskipTests package" unless File.file?(jar)
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
command = [java, "-cp", jar, File.join(__dir__, "SQLStorageOracle.java")]
run = lambda do |*arguments|
  output, error, status = Open3.capture3(*command, *arguments)
  abort error unless status.success?
  output
end
encode = lambda do |value|
  buffer = storage::Buffer.new
  storage::Codecs::VALUE.write(buffer, value)
  buffer.data.unpack1("H*")
end
read_native = lambda do |path|
  storage::Store.open(path, read_only: true) do |store|
    rows = store.open_map("table.3").to_h.transform_values { it.current.values.map { |value| encode.call(value) } }
    indexes = store.map_names.select { it.start_with?("index.") }.map { store.open_map(it).size }
    [rows, indexes]
  end
end
dump = lambda do |path|
  run.call("dump-sql", path).each_line.to_h do |line|
    id, *values = line.chomp.split("\t")
    [id.to_i, values]
  end
end
checks = 0
assert = lambda do |condition, message|
  abort message unless condition
  checks += 1
end

Dir.mktmpdir("sql-storage-reference-") do |directory|
  [:none, :fast, :high].each do |compression|
    base = File.join(directory, compression.to_s)
    path = "#{base}.mv.db"
    run.call("create-sql", base)
    expected = dump.call(base)
    actual, counts = read_native.call(path)
    assert.call(expected.length == 180 && expected == actual, "Native SQL row decoding differs (#{compression})")
    assert.call(counts == [180, 180], "Native secondary index decoding differs (#{compression})")
    storage::Store.open(path, compression: compression, keys_per_page: 6) do |store|
      table = store.open_map("table.3")
      old = table[1]
      values = old.current.values.dup
      values[1] = storage::Value.new(:varchar, "native 😀")
      values[2] = storage::Value.new(:numeric, storage::Decimal.new(-987654321012345600, 4))
      values[3] = storage::Value.new(:null, nil)
      table[1] = storage::VersionedValue.new(current: old.current.with(values: values))
      expected[1] = values.map { encode.call(it) }
      store.map_names.select { it.start_with?("index.") }.each do |name|
        index = store.open_map(name)
        next unless index.key_type.indexes == [1]

        key, value = index.find { |row, _value| row.key == 1 }
        index.delete(key)
        indexed = key.values.dup
        indexed[1] = values[1]
        index[key.with(values: indexed)] = value
      end
      store.commit
    end
    assert.call(expected == dump.call(base), "JDBC cannot reopen native SQL rows (#{compression})")
    run.call("check-index", base)
    checks += 1
    run.call("mutate-sql", base)
    expected = dump.call(base)
    actual, counts = read_native.call(path)
    assert.call(expected.key?(1000) && !expected.key?(180) && expected == actual, "Native reopen after JDBC changes differs (#{compression})")
    assert.call(counts == [180, 180], "Secondary indexes differ after JDBC changes (#{compression})")

    pending = File.join(directory, "pending-#{compression}.mv")
    run.call("create-pending", pending)
    storage::Store.open(pending, compression: compression, keys_per_page: 2) do |store|
      map = store.open_map("pending")
      assert.call(map[1].current.data == 20 && map[1].committed.data == 10 && map[2].current.nil? && map[2].committed.data == 11, "Pending transaction was decoded incorrectly")
      map.each { |key, value| map[key] = value }
      store.commit
    end
    run.call("recover-pending", pending)
    storage::Store.open(pending, read_only: true) do |store|
      map = store.open_map("pending")
      assert.call(map.size == 2 && map[1].current.data == 10 && map[2].current.data == 11 && map[1].committed?, "Java could not recover native versioned rows")
    end
  end
end

puts "SQL storage: #{checks} cross-engine checks passed (180 rows, 18 columns, indexes, JDBC reopen and preserved pending transactions in each compression mode)"

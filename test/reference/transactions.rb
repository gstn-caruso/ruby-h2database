# frozen_string_literal: true

require "open3"
require "tmpdir"

root = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(root, "lib"))
require "h2/mvstore"
m = H2::MVStore
jar = ENV.fetch("H2_REFERENCE_JAR", File.join(root, "h2/target/h2-2.5.259-SNAPSHOT.jar"))
abort "Build the Java reference first" unless File.file?(jar)
java = ENV["JAVA_HOME"] ? File.join(ENV.fetch("JAVA_HOME"), "bin/java") : "java"
command = [java, "-cp", jar, File.join(__dir__, "TransactionOracle.java")]
run = lambda do |*args|
  output, error, status = Open3.capture3(*command, *args)
  abort error unless status.success?
  output
end
checks = 0
assert = lambda do |condition, message|
  abort message unless condition
  checks += 1
end
decode = ->(hex) { [hex].pack("H*").force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8) }
java_dump = lambda do |path|
  run.call("dump", path).each_line.to_h { |line| line.chomp.split("\t", -1).map { decode.call(it) } }
end
marked_snapshot = lambda do |path|
  run.call("marked-snapshot", path).each_line.to_h { |line| line.chomp.split("\t", -1).map { decode.call(it) } }
end
native_dump = lambda do |path|
  m::TransactionStore.open(path) { |store| store.transaction { it.open_map("data").to_h } }
end
trace = lambda do |path|
  lines = []
  emit = ->(name, value) { lines << "#{name}\t#{value.nil? ? '-' : value}\n" }
  m::TransactionStore.open(path) do |store|
    store.transaction { it.open_map("data")["a"] = "zero" }
    first, second = store.begin_transaction, store.begin_transaction
    a, b = first.open_map("data"), second.open_map("data")
    emit.call("put", a.put("a", "one"))
    emit.call("own", a["a"])
    emit.call("other", b["a"])
    a["new"] = "fresh"
    emit.call("hidden", b["new"])
    emit.call("size", b.size)
    begin
      b["a"] = "conflict"
      emit.call("conflict", "missing")
    rescue m::Error => error
      emit.call("conflict", error.code)
    end
    emit.call("try", b.try_put("a", "conflict"))
    b["b"] = "two"
    save = first.savepoint
    a["a"] = "second"
    a.delete("a")
    a["transient"] = "discarded"
    first.rollback_to(save)
    emit.call("restored", a["a"])
    emit.call("discarded", a["transient"])
    emit.call("if-absent", a.put_if_absent("a", "ignored"))
    emit.call("lock", a.lock("a"))
    emit.call("missing-lock", a.lock("absent"))
    first.commit
    emit.call("visible", b["a"])
    emit.call("insert-visible", b["new"])
    second.commit
    store.transaction { emit.call("final-size", it.open_map("data").size) }
  end
  lines.join
end
create_native = lambda do |path, mode, compression|
  store = m::TransactionStore.open(path, compression: compression, keys_per_page: 3)
  store.transaction do |tx|
    map = tx.open_map("data")
    map["a"] = "zero"
    map["obsolete"] = "old"
  end
  tx = store.begin_transaction
  map = tx.open_map("data")
  map["a"] = "first update"
  map["a"] = "decided 😀"
  map.delete("obsolete")
  map["new"] = "inserted"
  case mode
  when :marked
    calls = 0
    store.store.define_singleton_method(:commit) do
      calls += 1
      raise m::Error.new(2, "Crash before cleanup") if calls == 2

      super()
    end
    begin
      tx.commit
      abort "Commit interruption was not reached"
    rescue m::Error => error
      raise unless error.code == 2
    end
  when :prepared then tx.prepare(name: "payment 😀")
  when :pending then store.checkpoint
  end
ensure
  store&.close
end
base = {"a" => "zero", "obsolete" => "old"}
decided = {"a" => "decided 😀", "new" => "inserted"}

Dir.mktmpdir("transaction-reference-") do |directory|
  reference_gap = File.join(directory, "java-marker-recovery-gap.mv")
  run.call("create", reference_gap, "marked")
  unless java_dump.call(reference_gap) == base
    abort "Java commit-marker recovery behavior changed; revisit the recorded reference limitation"
  end
  assert.call(native_dump.call(reference_gap) == decided, "Native recovery did not finish Java's stranded commit decision")
  native_trace_path = File.join(directory, "native-trace.mv")
  expected = run.call("trace", File.join(directory, "java-trace.mv"))
  assert.call(expected == trace.call(native_trace_path), "Transaction operation trace differs from Java")
  assert.call(java_dump.call(native_trace_path) == {"a" => "one", "b" => "two", "new" => "fresh"}, "Java cannot read native committed transaction maps")
  [:none, :fast, :high].each do |compression|
    [:pending, :marked, :prepared].each do |mode|
      path = File.join(directory, "java-#{compression}-#{mode}.mv")
      run.call("create", path, mode.to_s)
      m::TransactionStore.open(path, compression: compression) do |store|
        if mode == :prepared
          assert.call(store.in_doubt.size == 1 && store.in_doubt.first.name == "payment 😀", "Native prepared transaction metadata differs")
          store.in_doubt.first.commit
        end
        rows = store.transaction { it.open_map("data").to_h }
        assert.call(rows == (mode == :pending ? base : decided), "Native #{mode} recovery differs (#{compression})")
      end
      assert.call(java_dump.call(path) == (mode == :pending ? base : decided), "Java reopen after native #{mode} recovery differs")
    end
    [:pending, :marked].each do |mode|
      path = File.join(directory, "native-#{compression}-#{mode}.mv")
      create_native.call(path, mode, compression)
      expected = mode == :pending ? base : decided
      if mode == :marked
        assert.call(marked_snapshot.call(path) == expected, "Java cannot decode native commit decision or values (#{compression})")
        assert.call(native_dump.call(path) == expected, "Native commit-decision recovery differs")
        assert.call(java_dump.call(path) == expected, "Java cannot reopen completed native recovery")
      else
        assert.call(java_dump.call(path) == expected, "Java cannot recover native #{mode} transaction (#{compression})")
        assert.call(native_dump.call(path) == expected, "Native reopen after Java #{mode} recovery differs")
      end
    end
    [:commit, :rollback].each do |resolution|
      path = File.join(directory, "native-#{compression}-prepared-#{resolution}.mv")
      create_native.call(path, :prepared, compression)
      run.call("#{resolution}-prepared", path)
      expected = resolution == :commit ? decided : base
      assert.call(java_dump.call(path) == expected, "Java cannot #{resolution} native prepared transaction")
      assert.call(native_dump.call(path) == expected, "Native reopen after Java prepared #{resolution} differs")
    end
  end
  child = <<~'RUBY'
    require "h2/mvstore"
    m = H2::MVStore
    store = m::TransactionStore.open(ARGV.fetch(0))
    store.transaction do |tx|
      map = tx.open_map("data")
      map["a"] = "zero"
      map["obsolete"] = "old"
    end
    tx = store.begin_transaction
    map = tx.open_map("data")
    map["a"] = "decided 😀"
    map.delete("obsolete")
    map["new"] = "inserted"
    case ARGV.fetch(1)
    when "pending" then store.checkpoint
    when "prepared" then tx.prepare(name: "payment 😀")
    when "marked"
      store.store.define_singleton_method(:commit) do
        result = super()
        Process.kill(:KILL, Process.pid)
        result
      end
      tx.commit
    end
    Process.kill(:KILL, Process.pid)
  RUBY
  [:pending, :prepared, :marked].each do |mode|
    path = File.join(directory, "killed-#{mode}.mv")
    _output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.join(root, "lib"), "-e", child, path, mode.to_s)
    assert.call(status.signaled? && status.termsig == 9, "Transaction writer did not reach #{mode} crash state: #{error}")
    case mode
    when :pending
      assert.call(java_dump.call(path) == base, "Java did not roll back killed native transaction")
      assert.call(native_dump.call(path) == base, "Native reopen after Java crash recovery differs")
    when :prepared
      run.call("commit-prepared", path)
      assert.call(native_dump.call(path) == decided, "Prepared native transaction was lost after process death")
    when :marked
      assert.call(marked_snapshot.call(path) == decided, "Java did not decode killed native commit decision")
      assert.call(native_dump.call(path) == decided, "Native commit recovery failed after process death")
      assert.call(java_dump.call(path) == decided, "Java could not reopen recovered native commit")
    end
  end
  sql_base = File.join(directory, "sql-undo")
  sql_command = [java, "-cp", jar, File.join(__dir__, "SQLStorageOracle.java")]
  sql_run = lambda do |*args|
    output, error, status = Open3.capture3(*sql_command, *args)
    abort error unless status.success?
    output
  end
  sql_run.call("pending-sql", sql_base)
  m::TransactionStore.open("#{sql_base}.mv.db") do |store|
    store.transaction do |tx|
      table = tx.open_map("table.3")
      assert.call(table.size == 180 && table[1].values[1].data == "text-1" && table[180] && table[1000].nil?, "Native SQL-table undo recovery differs")
    end
  end
  rows = sql_run.call("dump-sql", sql_base).lines
  assert.call(rows.size == 180 && rows.first.start_with?("1\t") && rows.last.start_with?("180\t"), "JDBC could not reopen native recovery of SQL tables and indexes")
end

puts "Transactions: #{checks} cross-engine checks passed (visibility, locks, savepoints, undo recovery, commit decisions, prepared transactions and process death)"
puts "Java reference limitation reproduced: Transaction.commit ignores a recovered STATUS_COMMITTED transaction; native recovery completes it."

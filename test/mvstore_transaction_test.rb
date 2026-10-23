# frozen_string_literal: true

require_relative "test_helper"
require "h2/mvstore"
require "tmpdir"
require "fileutils"

class MVStoreTransactionTest < Minitest::Test
  M = H2::MVStore

  def setup
    @directory = Dir.mktmpdir("mvstore-transactions-")
    @path = File.join(@directory, "transactions.mv")
  end

  def teardown
    @transactions&.close
    FileUtils.remove_entry(@directory)
  end

  def transactions(**options)
    @transactions ||= M::TransactionStore.open(@path, **options)
  end

  def test_new_maps_commit_and_reopen_with_inferred_registered_types
    transactions.transaction do |tx|
      tx.open_map("words")["hello"] = "Ruby 😀"
      tx.open_map("numbers", key_type: :long, value_type: :long)[7] = -9
    end
    transactions.close
    @transactions = nil
    transactions.transaction do |tx|
      assert_equal "Ruby 😀", tx.open_map("words")["hello"]
      assert_equal(-9, tx.open_map("numbers")[7])
    end
  end

  def test_read_committed_hides_other_updates_deletes_and_inserts
    transactions.transaction { it.open_map("data")["key"] = "committed" }
    writer, reader = transactions.begin_transaction, transactions.begin_transaction
    a, b = writer.open_map("data"), reader.open_map("data")
    a["key"] = "pending"
    a["new"] = "inserted"
    assert_equal "pending", a["key"]
    assert_equal "committed", b["key"]
    assert_nil b["new"]
    assert_equal({"key" => "committed"}, b.to_h)
    a.delete("key")
    assert_nil a["key"]
    assert_equal "committed", b["key"]
    writer.commit
    assert_equal({"new" => "inserted"}, b.to_h)
    reader.rollback
  end

  def test_row_locks_and_put_if_absent
    first, second = transactions.begin_transaction, transactions.begin_transaction
    a, b = first.open_map("data"), second.open_map("data")
    assert_nil a.put("key", "one")
    assert_equal "one", a.put_if_absent("key", "ignored")
    assert_equal 101, assert_raises(M::Error) { b["key"] = "conflict" }.code
    refute b.try_put("key", "conflict")
    b["other"] = "independent"
    first.rollback
    assert_nil b.put_if_absent("key", "two")
    assert_equal "two", b.lock("key")
    second.commit
  end

  def test_savepoints_restore_repeated_changes_and_enumeration
    tx = transactions.begin_transaction
    map = tx.open_map("data")
    map["key"] = "first"
    savepoint = tx.savepoint
    map["key"] = "second"
    map.delete("key")
    map["new"] = "discarded"
    tx.rollback_to(savepoint)
    assert_equal({"key" => "first"}, map.to_h)
    map["key"] = "third"
    tx.commit
    transactions.transaction { assert_equal "third", it.open_map("data")["key"] }
  end

  def test_transaction_blocks_rollback_on_errors_and_nonlocal_return
    assert_raises(RuntimeError) do
      transactions.transaction { |tx| tx.open_map("data")["key"] = "bad"; raise "failure" }
    end
    assert_equal :returned, leave_transaction
    transactions.transaction { assert_empty it.open_map("data").to_h }
  end

  def test_native_recovery_rolls_back_a_real_java_interrupted_transaction
    FileUtils.cp(File.expand_path("fixtures/mvstore/java-pending.mv", __dir__), @path)
    transactions.transaction do |tx|
      map = tx.open_map("pending")
      assert_equal [1, 2], map.map(&:first)
      assert_equal 10, map[1].data
      assert_equal 11, map[2].data
      map[1] = M::Value.new(:integer, 99)
    end
    transactions.close
    @transactions = nil
    transactions.transaction { assert_equal 99, it.open_map("pending")[1].data }
  end

  def test_prepared_transactions_survive_close_and_can_be_resolved
    tx = transactions.begin_transaction
    tx.open_map("data")["key"] = "prepared"
    tx.prepare(name: "payment 😀")
    assert_equal :prepared, tx.status
    transactions.close
    @transactions = nil
    prepared = transactions.in_doubt.fetch(0)
    assert_equal "payment 😀", prepared.name
    reader = transactions.begin_transaction
    assert_nil reader.open_map("data")["key"]
    assert_equal 101, assert_raises(M::Error) { reader.open_map("data")["key"] = "conflict" }.code
    prepared.commit
    assert_equal "prepared", reader.open_map("data")["key"]
    reader.rollback
    assert_empty transactions.in_doubt
  end

  def test_durable_commit_marker_recovers_when_cleanup_fails
    tx = transactions.begin_transaction
    tx.open_map("data")["key"] = "decided"
    raw = transactions.store
    calls = 0
    raw.define_singleton_method(:commit) do
      calls += 1
      raise M::Error.new(2, "Injected cleanup failure") if calls == 2

      super()
    end
    assert_equal 2, assert_raises(M::Error) { tx.commit }.code
    assert raw.closed?
    @transactions = nil
    transactions.transaction { assert_equal "decided", it.open_map("data")["key"] }
  end

  def test_read_only_transaction_reads_committed_values_without_recovery_writes
    FileUtils.cp(File.expand_path("fixtures/mvstore/java-pending.mv", __dir__), @path)
    before = File.binread(@path)
    transactions(read_only: true).transaction do |tx|
      map = tx.open_map("pending")
      assert_equal [1, 2], map.map(&:first)
      assert_equal 10, map[1].data
      assert_equal 2, assert_raises(M::Error) { map[1] = M::Value.new(:integer, 9) }.code
    end
    transactions.close
    assert_equal before, File.binread(@path)
  end

  def test_slot_limits_closed_handles_and_unsupported_isolation
    transactions(max_transactions: 1)
    tx = transactions.begin_transaction
    map = tx.open_map("data")
    assert_equal 102, assert_raises(M::Error) { transactions.begin_transaction }.code
    tx.rollback
    assert_equal 103, assert_raises(M::Error) { map["key"] }.code
    assert_equal 5, assert_raises(M::Error) { transactions.begin_transaction(isolation: :serializable) }.code
    transactions.transaction { |next_tx| assert_equal tx.id, next_tx.id }
  end

  def test_waiters_resume_after_rollback_to_savepoint
    first, second = transactions.begin_transaction, transactions.begin_transaction(timeout_ms: 2000)
    a, b = first.open_map("data"), second.open_map("data")
    savepoint = first.savepoint
    a["key"] = "locked"
    result = Queue.new
    thread = Thread.new { result << b.put("key", "after rollback") }
    wait_until { second.blocker_id == first.id }
    first.rollback_to(savepoint)
    assert thread.join(2), "waiter did not finish"
    assert_nil result.pop
    second.commit
    first.rollback
    transactions.transaction { assert_equal "after rollback", it.open_map("data")["key"] }
  ensure
    thread&.kill if thread&.alive?
  end

  def test_deadlocks_abort_the_youngest_transaction_and_release_its_rows
    first, second = transactions.begin_transaction(timeout_ms: 2000), transactions.begin_transaction(timeout_ms: 2000)
    a, b = first.open_map("data"), second.open_map("data")
    a["a"] = "first"
    b["b"] = "second"
    thread = Thread.new { a["b"] = "survivor" }
    wait_until { first.blocker_id == second.id }
    assert_equal 105, assert_raises(M::Error) { b["a"] = "cycle" }.code
    assert second.closed?
    assert thread.join(2), "deadlock survivor did not finish"
    first.commit
    transactions.transaction { assert_equal({"a" => "first", "b" => "survivor"}, it.open_map("data").to_h) }
  ensure
    thread&.kill if thread&.alive?
  end

  def test_lock_timeouts_preserve_the_transaction_and_changes
    first, second = transactions.begin_transaction, transactions.begin_transaction(timeout_ms: 10)
    first.open_map("data")["key"] = "held"
    map = second.open_map("data")
    map["own"] = "retained"
    assert_equal 101, assert_raises(M::Error) { map["key"] = "blocked" }.code
    assert_equal :open, second.status
    assert_equal "retained", map["own"]
    first.rollback
    second.commit
  end

  def test_a_store_has_one_transaction_coordinator_and_can_attach_again_after_close
    raw = M::Store.open(@path)
    @transactions = M::TransactionStore.new(raw)
    @transactions.transaction { it.open_map("data")["key"] = "value" }
    assert_equal 103, assert_raises(M::Error) { M::TransactionStore.new(raw) }.code
    refute raw.closed?
    @transactions.close
    @transactions = M::TransactionStore.new(raw)
    @transactions.transaction { assert_equal "value", it.open_map("data")["key"] }
  ensure
    @transactions&.close
    raw&.close
  end

  def test_java_prepared_object_vectors_reencode_identically
    lines = File.readlines(File.expand_path("fixtures/mvstore/transaction-objects.tsv", __dir__))
    assert_equal 20, lines.size
    lines.each do |line|
      label, hex = line.chomp.split("\t")
      buffer = M::Buffer.new([hex].pack("H*"))
      value = M::Codecs::OBJECT.read(buffer)
      assert_equal 0, buffer.remaining, label
      output = M::Buffer.new
      M::Codecs::OBJECT.write(output, value)
      assert_equal hex, output.data.unpack1("H*"), label
    end
  end

  def test_multimap_commits_and_clear_failures_preserve_atomicity
    transactions.transaction do |tx|
      tx.open_map("first")["a"] = "one"
      tx.open_map("first")["b"] = "two"
      tx.open_map("second")["a"] = "other"
    end
    blocker, writer = transactions.begin_transaction, transactions.begin_transaction
    blocker.open_map("first").lock("b")
    target = writer.open_map("first")
    assert_equal 101, assert_raises(M::Error) { target.clear }.code
    assert_equal({"a" => "one", "b" => "two"}, target.to_h)
    blocker.rollback
    target.clear
    writer.open_map("second")["a"] = "changed"
    observer = transactions.begin_transaction
    assert_equal 2, observer.open_map("first").size
    assert_equal "other", observer.open_map("second")["a"]
    writer.commit
    assert_equal 0, observer.open_map("first").size
    assert_equal "changed", observer.open_map("second")["a"]
    observer.commit
  end

  def test_read_only_prepared_transactions_cannot_be_resolved
    tx = transactions.begin_transaction
    tx.open_map("data")["key"] = "prepared"
    tx.prepare(name: "payment 😀")
    transactions.close
    @transactions = nil
    prepared = transactions(read_only: true).in_doubt.fetch(0)
    assert_equal 2, assert_raises(M::Error) { prepared.commit }.code
    assert_equal 2, assert_raises(M::Error) { prepared.rollback }.code
    assert_equal :prepared, prepared.status
  end

  def test_prepared_read_transaction_retains_its_name_on_native_reopen
    tx = transactions.begin_transaction
    tx.prepare(name: "read-only work")
    transactions.close
    @transactions = nil
    prepared = transactions.in_doubt.fetch(0)
    assert_equal "read-only work", prepared.name
    prepared.rollback
    assert_empty transactions.in_doubt
  end

  private

  def wait_until
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    until yield
      raise "transaction did not enter lock wait" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Thread.pass
    end
  end

  def leave_transaction
    transactions.transaction do |tx|
      tx.open_map("data")["key"] = "discarded"
      return :returned
    end
  end
end

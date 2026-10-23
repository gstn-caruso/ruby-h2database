# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"
require "fileutils"

class PersistenceTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("ruby-h2-sql-")
    @path = File.join(@directory, "database")
  end

  def teardown
    @database&.close
    FileUtils.remove_entry(@directory)
  end

  def connect(**options, &block)
    H2.connect(path: @path, **options, &block)
  end

  def test_tables_values_defaults_and_constraints_reopen
    connect do |connection|
      connection.execute("CREATE TABLE people(id INT PRIMARY KEY, name VARCHAR(40) UNIQUE, amount NUMERIC(12,3) DEFAULT 1.250, active BOOLEAN)")
      connection.execute("INSERT INTO people(id, name, active) VALUES (?, ?, ?)", 7, "Ada 😀", true)
      connection.execute("INSERT INTO people VALUES (8, NULL, 99.125, FALSE)")
    end
    assert File.file?("#{@path}.mv.db")
    connect do |connection|
      assert_equal [[7, "Ada 😀", BigDecimal("1.250"), true], [8, nil, BigDecimal("99.125"), false]], connection.execute("TABLE people ORDER BY id").rows
      assert_equal 23505, assert_raises(H2::Error) { connection.execute("INSERT INTO people VALUES (7, 'duplicate', 0, TRUE)") }.code
      connection.execute("INSERT INTO people(id,name) VALUES(9,'Grace')")
    end
    connect { assert_equal [[BigDecimal("1.250")]], it.execute("SELECT amount FROM people WHERE id=9").rows }
  end

  def test_composite_keys_and_tables_without_primary_keys
    connect do |connection|
      connection.execute("CREATE TABLE pairs(a VARCHAR, b INT, v CHAR(4), PRIMARY KEY(a,b))")
      connection.execute("INSERT INTO pairs VALUES('a',1,'x'),('a',2,'y')")
      connection.execute("CREATE TABLE bag(a INT, b VARCHAR)")
      connection.execute("INSERT INTO bag VALUES(1,'same'),(1,'same'),(NULL,NULL)")
    end
    connect do |connection|
      assert_equal [["a", 1, "x   "], ["a", 2, "y   "]], connection.execute("TABLE pairs ORDER BY b").rows
      assert_equal [[3]], connection.execute("SELECT COUNT(*) FROM bag").rows
      assert_equal 23505, assert_raises(H2::Error) { connection.execute("INSERT INTO pairs VALUES('a',1,'z')") }.code
    end
  end

  def test_transactions_savepoints_and_connection_close_rollback
    connect { it.execute_script("CREATE TABLE t(id INT PRIMARY KEY, v INT); INSERT INTO t VALUES(1,10)") }
    connect do |connection|
      connection.execute("BEGIN")
      connection.execute("UPDATE t SET v=20")
      connection.execute("SAVEPOINT before_second")
      connection.execute("UPDATE t SET v=30")
      connection.execute("ROLLBACK TO before_second")
      connection.execute("COMMIT")
      connection.execute("BEGIN")
      connection.execute("UPDATE t SET v=999")
    end
    connect { assert_equal [[20]], it.execute("SELECT v FROM t").rows }
  end

  def test_shared_database_connections_keep_conflict_detection
    @database = H2::Database.new(path: @path)
    a, b = @database.connect, @database.connect
    a.execute_script("CREATE TABLE t(id INT PRIMARY KEY, v INT); INSERT INTO t VALUES(1,10)")
    a.execute("BEGIN")
    a.execute("UPDATE t SET v=20")
    b.execute("UPDATE t SET v=30")
    assert_equal 90131, assert_raises(H2::Error) { a.commit }.code
    a.rollback
    a.close
    b.close
    @database.close
    connect { assert_equal [[30]], it.execute("SELECT v FROM t").rows }
  end

  def test_ctas_insert_select_drop_truncate_and_recreate
    connect do |connection|
      connection.execute("CREATE TABLE source AS SELECT x AS id FROM SYSTEM_RANGE(1,4)")
      connection.execute("CREATE TABLE target(id INT PRIMARY KEY)")
      connection.execute("INSERT INTO target SELECT id FROM source")
      assert_equal 4, connection.execute("TRUNCATE TABLE source").update_count
      connection.execute("DROP TABLE source")
      connection.execute("CREATE TABLE source(v VARCHAR DEFAULT 'new')")
      connection.execute("INSERT INTO source DEFAULT VALUES")
    end
    connect do |connection|
      assert_equal [[1], [2], [3], [4]], connection.execute("TABLE target ORDER BY id").rows
      assert_equal [["new"]], connection.execute("TABLE source").rows
    end
  end

  def test_dynamic_defaults_capture_parameters_and_query_current_data_after_reopen
    connect do |connection|
      connection.execute("CREATE TABLE source(v INT)")
      connection.execute("INSERT INTO source VALUES(10)")
      connection.execute("CREATE TABLE target(v INT DEFAULT (SELECT MAX(v)+? FROM source))", 7)
    end
    connect do |connection|
      connection.execute("UPDATE source SET v=20")
      connection.execute("INSERT INTO target DEFAULT VALUES")
      assert_equal [[27]], connection.execute("TABLE target").rows
      assert_equal 90107, assert_raises(H2::Error) { connection.execute("DROP TABLE source") }.code
    end
  end

  def test_read_only_files_and_credentials
    connect(password: "sëcret 😀") { it.execute_script("CREATE TABLE t(v INT); INSERT INTO t VALUES(42)") }
    assert_equal 28000, assert_raises(H2::Error) { connect(password: "wrong") }.code
    connect(password: "sëcret 😀", read_only: true) do |connection|
      assert_equal [[42]], connection.execute("TABLE t").rows
      assert_equal 90097, assert_raises(H2::Error) { connection.execute("UPDATE t SET v=1") }.code
    end
  end

  def test_database_close_invalidates_connections_and_releases_file_lock
    @database = H2::Database.new(path: @path)
    connection = @database.connect
    connection.execute("CREATE TABLE t(v INT)")
    assert_equal 90020, assert_raises(H2::Error) { connect }.code
    @database.close
    assert connection.closed?
    assert_equal 90007, assert_raises(H2::Error) { connection.execute("TABLE t") }.code
    connection.close
    connect { assert_empty it.execute("TABLE t").rows }
  end

  def test_existing_java_database_reads_updates_and_preserves_its_index
    FileUtils.cp(File.expand_path("fixtures/mvstore/java-sql.mv.db", __dir__), "#{@path}.mv.db")
    connect do |connection|
      assert_equal [[1, "native storage reference"]], connection.execute("TABLE test").rows
      connection.execute("UPDATE test SET v='Ruby' WHERE id=1")
      connection.execute("INSERT INTO test VALUES(2,'later')")
    end
    connect { assert_equal [[1, "Ruby"], [2, "later"]], it.execute("TABLE test ORDER BY id").rows }
  end

  def test_unicode_sql_escapes_survive_persistent_defaults_and_identifiers
    connect do |connection|
      assert_equal [["a0a%a"]], connection.execute("SELECT U&'a\\0030a\\+000025a'").rows
      assert_equal [["a0a%a"]], connection.execute("SELECT U&'az0030az+000025a' UESCAPE 'z'").rows
      assert_equal [["A"]], connection.execute("SELECT U&'!0041' /* comment */ UESCAPE /* comment */ '!'").rows
      assert_equal 90095, assert_raises(H2::Error) { connection.execute("SELECT U&'\\003'") }.code
      assert_equal 42000, assert_raises(H2::Error) { connection.execute("SELECT U&'a' UESCAPE '0'") }.code
      connection.execute("CREATE TABLE U&\"t\\0061ble\"(v VARCHAR DEFAULT U&'O''Brien \\+01f600')")
      connection.execute('INSERT INTO "table" DEFAULT VALUES')
    end
    connect { assert_equal [["O'Brien 😀"]], it.execute('TABLE "table"').rows }
  end

  def test_unpaired_utf16_defaults_are_preserved_in_h2_metadata
    connect do |connection|
      connection.execute("CREATE TABLE t(v VARCHAR DEFAULT U&'\\d800')")
      connection.execute("INSERT INTO t DEFAULT VALUES")
    end
    connect do |connection|
      value = connection.execute("TABLE t").rows.first.first
      assert_equal [0xd800], H2::MVStore::Codecs::STRING.units(value)
      connection.execute("INSERT INTO t DEFAULT VALUES")
      assert_equal 2, connection.execute("SELECT COUNT(*) FROM t").rows.first.first
    end
  end

  def test_write_failures_recover_one_atomic_sql_commit
    [:chunk, :cleanup].each do |phase|
      path = File.join(@directory, phase.to_s)
      @database = H2::Database.new(path: path)
      connection = @database.connect
      connection.execute_script("CREATE TABLE a(v INT); CREATE TABLE b(v INT); INSERT INTO a VALUES(10); INSERT INTO b VALUES(10)")
      connection.execute("BEGIN")
      connection.execute("UPDATE a SET v=20")
      connection.execute("UPDATE b SET v=30")
      raw = @database.instance_variable_get(:@storage).instance_variable_get(:@store)
      if phase == :chunk
        storage = raw.instance_variable_get(:@storage)
        storage.define_singleton_method(:write_at) do |offset, bytes|
          super(offset, bytes.byteslice(0, bytes.bytesize / 2))
          raise H2::MVStore::Error.new(2, "Injected partial SQL chunk write")
        end
      else
        calls = 0
        raw.define_singleton_method(:commit) do
          calls += 1
          raise H2::MVStore::Error.new(2, "Injected SQL cleanup failure") if calls == 2

          super()
        end
      end
      assert_equal 90028, assert_raises(H2::Error) { connection.commit }.code
      assert connection.closed?
      connection.close
      @database.close
      if phase == :cleanup
        assert_equal 28000, assert_raises(H2::Error) { H2.connect(path: path, password: "wrong") }.code
        H2::MVStore::Store.open("#{path}.mv.db", read_only: true) do |store|
          refute store.open_map("table.3").first.last.committed?, "Failed authentication must not recover stored transactions"
        end
      end
      H2.connect(path: path) do |recovered|
        expected = phase == :chunk ? [[10, 10]] : [[20, 30]]
        assert_equal expected, recovered.execute("SELECT a.v,b.v FROM a CROSS JOIN b").rows
      end
    end
  end
end

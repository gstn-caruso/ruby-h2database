# frozen_string_literal: true

require_relative 'test_helper'
require 'tmpdir'

class LobValuesTest < DatabaseTest
  def test_lob_aliases_and_precision_suffixes
    execute('CREATE TABLE t(b BINARY LARGE OBJECT(1K),c NATIONAL CHARACTER LARGE OBJECT(1 M),n NCLOB,i IMAGE)')
    execute("INSERT INTO t VALUES(X'00ff','😀café','n',X'61')")
    result = execute('TABLE t')
    assert_equal %w[BLOB CLOB CLOB BLOB], result.types.map(&:name)
    assert_equal [1024,1048576], result.types.first(2).map(&:precision)
    assert_equal "\x00\xff".b, result.rows.first[0].bytes
    assert_equal '😀café', result.rows.first[1].to_s
    assert_sql_error 90008, 'CREATE TABLE overflow(b BLOB(8192P))'
    assert_sql_error 90008, 'CREATE TABLE zero(c CLOB(0))'
    assert_sql_error 42001, 'CREATE TABLE units(b BLOB(1K OCTETS))'
  end

  def test_cast_limits_and_conversion_rules
    result = rows("SELECT CAST('😀x' AS CLOB(1)),CAST(X'010203' AS BLOB(2)),CAST(CAST(X'ff' AS BLOB) AS CLOB)").first
    assert_equal '?', result[0].to_s
    assert_equal "\x01\x02".b, result[1].bytes
    assert_equal "\uFFFD", result[2].to_s
    assert_sql_error 22018, "SELECT CAST(CAST(X'61' AS BLOB) AS VARCHAR)"
    assert_sql_error 22018, "SELECT CAST(CAST('42' AS CLOB) AS INT)"
    execute('CREATE TABLE short(b BLOB(2),c CLOB(2))')
    assert_sql_error 22001, "INSERT INTO short VALUES(X'010203','abc')"
    assert_equal [[2,5,3]], rows("SELECT CHAR_LENGTH(CAST(X'00ff' AS BLOB)),OCTET_LENGTH(CAST('😀x' AS CLOB)),CHAR_LENGTH(CAST('😀x' AS CLOB))")
  end

  def test_lob_comparisons_collections_and_concatenation
    assert_equal [[true,true]], rows("SELECT CAST('a' AS CLOB)='a',CAST(X'61' AS BLOB)=X'61'")
    assert_sql_error 90110, "SELECT CAST(X'61' AS BLOB)='a'"
    assert_equal %w[a b], rows("SELECT CAST('b' AS CLOB) UNION SELECT 'a' ORDER BY 1").flatten.map(&:to_s)
    result = execute("SELECT CAST('a' AS CLOB)||CAST('b' AS CLOB),CAST(X'61' AS BLOB)||X'62'")
    assert_equal %w[VARCHAR VARBINARY], result.types.map(&:name)
    assert_equal [['ab','ab'.b]], result.rows
    value = rows("SELECT ROW(CAST('😀' AS CLOB),ARRAY[CAST(X'61' AS BLOB)])").first.first
    assert_equal '😀', value.values.first.to_s
    assert_equal 'a'.b, value.values.last.values.first.bytes
  end

  def test_immutable_typed_parameters_keep_their_lob_types
    bytes = +'payload'
    blob = H2::BlobValue.new(bytes)
    clob = H2::ClobValue.parse('😀café')
    bytes.replace('changed')
    result = execute('SELECT ?,?,CHAR_LENGTH(?),OCTET_LENGTH(?)',blob,clob,clob,blob)
    assert_equal %w[BLOB CLOB BIGINT BIGINT], result.types.map(&:name)
    assert_equal 'payload', result.rows.first.first.bytes
    assert_equal [6,7], result.rows.first.last(2)
    assert blob.frozen?
    assert blob.bytes.frozen?
    assert_equal 22018, assert_raises(H2::Error) { H2::ClobValue.new('abc',2) }.code
  end

  def test_large_lobs_use_external_maps_and_survive_sql_rollback
    Dir.mktmpdir('h2-sql-lobs') do |directory|
      path = File.join(directory,'db')
      binary = ('blob' * 100000).b
      text = '😀café' * 20000
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE t(id INT PRIMARY KEY,b BLOB,c CLOB)')
        connection.execute('INSERT INTO t VALUES(1,?,?)',binary,text)
        connection.execute('BEGIN')
        connection.execute("UPDATE t SET b=X'00',c='changed'")
        connection.execute('ROLLBACK')
        assert_equal [binary,text], connection.execute('SELECT b,c FROM t').rows.first.then { |b,c| [b.bytes,c.to_s] }
      end
      H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
        assert_equal 2, raw.open_map('lobMap').size
        assert_operator raw.open_map('lobData').size, :>, 0
        assert_equal 0, raw.open_map('tempLobMap').size
      end
      H2.connect(path: path) do |connection|
        assert_equal [binary,text], connection.execute('SELECT b,c FROM t').rows.first.then { |b,c| [b.bytes,c.to_s] }
        connection.execute("UPDATE t SET b=X'00',c='small'")
      end
      H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
        assert_equal 0, raw.open_map('lobMap').size
        assert_equal 0, raw.open_map('lobData').size
      end
    end
  end

  def test_nested_lobs_share_streams_keep_unchanged_ids_and_reclaim_on_truncate
    Dir.mktmpdir('h2-nested-lobs') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE t(id INT PRIMARY KEY,n INT,b BLOB,c CLOB,a BLOB ARRAY,r ROW(x CLOB))')
        connection.execute('INSERT INTO t VALUES(1,0,?,?,ARRAY[CAST(? AS BLOB)],ROW(CAST(? AS CLOB)))','b' * 1000,'😀' * 500,'b' * 1000,'😀' * 500)
        connection.execute('INSERT INTO t SELECT 2,n,b,c,a,r FROM t WHERE id=1')
      end
      ids = nil
      H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
        metadata = raw.open_map('lobMap').to_h
        ids = metadata.keys
        assert_equal 8, metadata.size
        assert_equal 2, metadata.values.map(&:stream_id).uniq.size
      end
      H2.connect(path: path) do |connection|
        connection.execute('UPDATE t SET n=7')
        row = connection.execute('SELECT a,r FROM t WHERE id=1').rows.first
        assert_equal 'b' * 1000, row.first.values.first.bytes
        assert_equal '😀' * 500, row.last.values.first.to_s
      end
      H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
        assert_equal ids, raw.open_map('lobMap').map(&:first)
      end
      H2.connect(path: path) { it.execute('TRUNCATE TABLE t') }
      H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |raw|
        assert_equal 0, raw.open_map('lobMap').size
        assert_equal 0, raw.open_map('lobData').size
      end
    end
  end

  def test_lob_commit_failures_recover_atomic_rows_and_cleanup_candidates
    Dir.mktmpdir('h2-lob-commit-failures') do |directory|
      [1,2,3,:partial].each do |phase|
        path = File.join(directory,phase.to_s)
        database = H2::Database.new(path: path)
        connection = database.connect
        connection.execute('CREATE TABLE t(b BLOB,c CLOB)')
        connection.execute('INSERT INTO t VALUES(?,?)','old' * 1000,'😀old' * 1000)
        connection.execute('BEGIN')
        connection.execute('UPDATE t SET b=?,c=?','new' * 1000,'漢new' * 1000)
        raw = database.instance_variable_get(:@storage).instance_variable_get(:@store)
        if phase == :partial
          disk = raw.instance_variable_get(:@storage)
          disk.define_singleton_method(:write_at) do |offset,bytes|
            super(offset,bytes.byteslice(0,bytes.bytesize / 2))
            raise H2::MVStore::Error.new(2,'Injected partial LOB chunk write')
          end
        else
          calls = 0
          raw.define_singleton_method(:commit) do
            calls += 1
            raise H2::MVStore::Error.new(2,'Injected LOB commit failure') if calls == phase

            super()
          end
        end
        assert_equal 90028, assert_raises(H2::Error) { connection.commit }.code
        assert connection.closed?
        database.close
        H2.connect(path: path) do |recovered|
          b,c = recovered.execute('TABLE t').rows.first
          assert_equal ([1,:partial].include?(phase) ? 'old' : 'new') * 1000, b.bytes
          assert_equal ([1,:partial].include?(phase) ? '😀old' : '漢new') * 1000, c.to_s
        end
        H2::MVStore::Store.open("#{path}.mv.db",read_only: true) do |store|
          assert_equal 2, store.open_map('lobMap').size
          assert_equal 0, store.open_map('ruby.lobCleanup').size
          assert_equal 0, store.open_map('tempLobMap').size
        end
      end
    end
  end

  def test_empty_lob_defaults_are_saved_as_valid_sql
    Dir.mktmpdir('h2-empty-lob-defaults') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute("CREATE TABLE t(b BLOB DEFAULT CAST(X'' AS BLOB),c CLOB DEFAULT CAST('' AS CLOB))")
        connection.execute('INSERT INTO t DEFAULT VALUES')
      end
      H2.connect(path: path) do |connection|
        connection.execute('INSERT INTO t DEFAULT VALUES')
        assert_equal [[0,0],[0,0]], connection.execute('SELECT OCTET_LENGTH(b),CHAR_LENGTH(c) FROM t').rows
      end
    end
    assert_sql_error 50100, 'CREATE TABLE lob_key(b BLOB PRIMARY KEY)'
    assert_sql_error 50100, 'CREATE TABLE nested_lob_key(a ROW(x CLOB) UNIQUE)'
  end

  def test_empty_inferred_lob_schemas_reopen_without_losing_the_table
    Dir.mktmpdir('h2-empty-lob-ctas') do |directory|
      path = File.join(directory,'db')
      H2.connect(path: path) do |connection|
        connection.execute('CREATE TABLE e AS SELECT ? AS b,? AS c',H2::BlobValue.new(''),H2::ClobValue.parse(''))
      end
      H2.connect(path: path) do |connection|
        result = connection.execute('TABLE e')
        assert_equal [0,0], result.types.map(&:precision)
        assert_equal [0,0], result.rows.first.map(&:precision)
        assert_equal 22001, assert_raises(H2::Error) { connection.execute("UPDATE e SET c='x'") }.code
      end
    end
    assert_sql_error 90008, 'CREATE TABLE forbidden(b BLOB(0))'
  end
end

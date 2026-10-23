# frozen_string_literal: true

require_relative "test_helper"
require "h2/cli"
require "stringio"
require "open3"
require "tempfile"
require "tmpdir"

class CLITest < Minitest::Test
  def test_executable_runs_a_script
    sql = "CREATE TABLE t(id INT, name VARCHAR); INSERT INTO t VALUES (1, 'Ruby'); SELECT * FROM t;"
    output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/h2", "--execute", sql)
    assert status.success?, error
    assert_empty error
    assert_equal "OK\nUpdate count: 1\nID\tNAME\n1\tRuby\n(1 row)\n", output
  end

  def test_reads_stdin
    output = StringIO.new
    status = H2::CLI.new.run([], input: StringIO.new("VALUES 1, 2;"), output: output)
    assert_equal 0, status
    assert_equal "C1\n1\n2\n(2 rows)\n", output.string
  end

  def test_persistent_database_survives_separate_executable_invocations
    Dir.mktmpdir("ruby-h2-cli-") do |directory|
      path = File.join(directory, "database")
      _output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/h2", "--database", path, "--execute", "CREATE TABLE t(v INT); INSERT INTO t VALUES(42);")
      assert status.success?, error
      output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/h2", "--database", path, "--read-only", "--execute", "TABLE t;")
      assert status.success?, error
      assert_equal "V\n42\n(1 row)\n", output
    end
  end

  def test_reads_sql_file
    Tempfile.create(["h2", ".sql"]) do |file|
      file.write("SELECT 42 AS answer;")
      file.flush
      output = StringIO.new
      assert_equal 0, H2::CLI.new.run([file.path], output: output)
      assert_equal "ANSWER\n42\n(1 row)\n", output.string
    end
  end

  def test_binary_bytes_and_uuid_have_printable_representations
    output = StringIO.new
    assert_equal 0, H2::CLI.new.run(["--execute", "SELECT X'00ff' AS b, UUID '01234567-89ab-cdef-0123-456789abcdef' AS u;"], output: output)
    assert_equal "B\tU\nX'00ff'\t01234567-89ab-cdef-0123-456789abcdef\n(1 row)\n", output.string
  end

  def test_lobs_keep_binary_output_and_escape_clob_text
    output = StringIO.new
    sql = "SELECT CAST(X'00ff' AS BLOB) AS b,CAST('a\nb' AS CLOB) AS c;"
    assert_equal 0, H2::CLI.new.run(['--execute',sql],output: output)
    assert_equal "B\tC\nX'00ff'\ta\\nb\n(1 row)\n", output.string
  end

  def test_error_exits_nonzero
    output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/h2", "--execute", "TABLE missing;")
    refute status.success?
    assert_empty output
    assert_includes error, "[42104]"
  end

  def test_calendar_values_and_epoch_keep_their_numeric_scale
    output = StringIO.new
    sql = "SELECT DATE_TRUNC(month,DATE '2000-02-29') AS d,LAST_DAY(DATE '2000-02-01') AS last_day,EXTRACT(epoch FROM TIME '00:00:00') AS e,EXTRACT(epoch FROM TIME '00:00:00.000000001') AS n;"
    assert_equal 0, H2::CLI.new.run(["--execute", sql], output: output)
    assert_equal "D\tLAST_DAY\tE\tN\n2000-02-01\t2000-02-29\t0\t0.000000001\n(1 row)\n", output.string
  end

  def test_escapes_control_characters_and_backslashes
    output = StringIO.new
    sql = "SELECT 'a\\b\tc\nd\r' AS value_text;"
    assert_equal 0, H2::CLI.new.run(["--execute", sql], output: output)
    assert_equal "VALUE_TEXT\na\\\\b\\tc\\nd\\r\n(1 row)\n", output.string
  end

  def test_subquery_labels_and_row_values_are_rendered_in_one_record
    output = StringIO.new
    assert_equal 0, H2::CLI.new.run(["--execute", "SELECT (SELECT 1), ROW(2, NULL) AS pair;"], output: output)
    assert_equal "1\tPAIR\n1\tROW (2, null)\n(1 row)\n", output.string
  end

  def test_help_version_and_invalid_options
    output = StringIO.new
    assert_equal 0, H2::CLI.new.run(["--help"], output: output)
    assert_includes output.string, "Usage: h2"
    output = StringIO.new
    assert_equal 0, H2::CLI.new.run(["--version"], output: output)
    assert_includes output.string, H2::VERSION
    error = StringIO.new
    assert_equal 1, H2::CLI.new.run(["--execute", "SELECT 1", "extra.sql"], error: error)
    assert_includes error.string, "provide either"
  end

  def test_rounding_preserves_numeric_scale_and_real_width_in_output
    output = StringIO.new
    sql = "SELECT ROUND(n,s) AS r,TRUNC(n,s) AS t,ROUND(CAST(0.285 AS REAL),2) AS f FROM (VALUES (1.255,2)) v(n,s);"
    assert_equal 0, H2::CLI.new.run(["--execute",sql],output: output)
    assert_equal "R\tT\tF\n1.260\t1.250\t0.29\n(1 row)\n", output.string
  end
end

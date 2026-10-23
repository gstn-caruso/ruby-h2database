# frozen_string_literal: true

require_relative "test_helper"
require "h2/cli"
require "stringio"
require "open3"
require "tempfile"

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

  def test_reads_sql_file
    Tempfile.create(["h2", ".sql"]) do |file|
      file.write("SELECT 42 AS answer;")
      file.flush
      output = StringIO.new
      assert_equal 0, H2::CLI.new.run([file.path], output: output)
      assert_equal "ANSWER\n42\n(1 row)\n", output.string
    end
  end

  def test_error_exits_nonzero
    output, error, status = Open3.capture3(RbConfig.ruby, "-Ilib", "exe/h2", "--execute", "TABLE missing;")
    refute status.success?
    assert_empty output
    assert_includes error, "[42102]"
  end

  def test_escapes_control_characters_and_backslashes
    output = StringIO.new
    sql = "SELECT 'a\\b\tc\nd\r' AS value_text;"
    assert_equal 0, H2::CLI.new.run(["--execute", sql], output: output)
    assert_equal "VALUE_TEXT\na\\\\b\\tc\\nd\\r\n(1 row)\n", output.string
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
end

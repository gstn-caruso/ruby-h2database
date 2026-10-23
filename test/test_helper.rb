# frozen_string_literal: true

require "minitest/autorun"
require "h2"

class DatabaseTest < Minitest::Test
  def setup
    @database = H2::Database.new
    @connection = @database.connect
  end

  def teardown
    @connection.close
  end

  def execute(sql, *parameters)
    @connection.execute(sql, *parameters)
  end

  def rows(sql, *parameters)
    execute(sql, *parameters).rows
  end

  def assert_sql_error(code, sql, *parameters)
    error = assert_raises(H2::Error) { execute(sql, *parameters) }
    assert_equal code, error.code
    error
  end
end

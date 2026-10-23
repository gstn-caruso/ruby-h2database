# frozen_string_literal: true

require_relative "h2/version"
require_relative "h2/error"
require_relative "h2/uuid_value"
require_relative "h2/binary_string"
require_relative "h2/temporal"
require_relative "h2/character_string"
require_relative "h2/row_value"
require_relative "h2/type"
require_relative "h2/result"
require_relative "h2/sql/nodes"
require_relative "h2/sql/lexer"
require_relative "h2/sql/parser"
require_relative "h2/sql/scope"
require_relative "h2/sql/temporal_operations"
require_relative "h2/sql/evaluator"
require_relative "h2/sql/row_set"
require_relative "h2/sql/sources"
require_relative "h2/sql/query_plan"
require_relative "h2/sql/set_plan"
require_relative "h2/sql/common_table"
require_relative "h2/sql/with_plan"
require_relative "h2/sql/queries"
require_relative "h2/table"
require_relative "h2/sql/executor"
require_relative "h2/connection"
require_relative "h2/database"

module H2
  def self.connect(**options, &block)
    Database.new(**options).connect(owns_database: true, &block)
  end
end

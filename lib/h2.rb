# frozen_string_literal: true

require_relative "h2/version"
require_relative "h2/error"
require_relative "h2/type"
require_relative "h2/result"
require_relative "h2/sql/nodes"
require_relative "h2/sql/lexer"
require_relative "h2/sql/parser"
require_relative "h2/sql/evaluator"
require_relative "h2/table"
require_relative "h2/sql/executor"
require_relative "h2/connection"
require_relative "h2/database"

module H2
  def self.connect(&block)
    Database.new.connect(&block)
  end
end

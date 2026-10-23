# frozen_string_literal: true

module H2
  module SQL
    class Queries
      def initialize(catalog, parameters, ctes: {})
        @catalog, @ctes = catalog, ctes.freeze
        @parameters = parameters
        @sources = Sources.new(catalog, parameters, self)
      end

      def with_cte(table)
        self.class.new(@catalog, @parameters, ctes: @ctes.merge(table.name => table))
      end

      def cte(name)
        @ctes[name]
      end

      def unbound
        self.class.new(@catalog, Array.new(@parameters.length, UNBOUND_PARAMETER), ctes: @ctes)
      end

      def for_definition
        self.class.new(@catalog, @parameters, ctes: @ctes.reject { |_name, table| table.preparing? })
      end

      def prepare(statement, outer_scope: nil)
        return WithPlan.new(statement, self, outer_scope) if statement.is_a?(WithQuery)

        klass = case statement
        when Select then SelectPlan
        when Values then ValuesPlan
        when SetQuery then SetPlan
        else raise Error.new(42000, "Expected query")
        end
        klass.new(statement, @parameters, self, @sources, outer_scope)
      end

      def execute(statement)
        return prepare(statement).execute unless statement.is_a?(Explain)

        query = statement.statement
        unless query.is_a?(Values) && query.order.empty? && !query.limit && !query.offset
          raise Error.new(50100, "EXPLAIN for this statement has not yet been ported")
        end
        prepare(query).execute
        plan = "VALUES " + query.rows.map { |row| "(#{row.map { Formatter.expression(it) }.join(', ')})" }.join(", ")
        Result.new(columns: ["PLAN"], types: [Type.new("VARCHAR", nil, nil)], rows: [[plan]])
      end
    end
  end
end

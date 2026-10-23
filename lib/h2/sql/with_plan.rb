# frozen_string_literal: true

module H2
  module SQL
    class WithPlan
      def initialize(statement, queries, outer_scope)
        names = []
        scoped = queries
        statement.definitions.each do |definition|
          raise Error.new(42101, "CTE #{definition.name} already exists") if names.include?(definition.name)

          table = CommonTable.new(definition, recursive: statement.recursive)
          definition_scope = scoped.for_definition
          table.prepare(statement.recursive ? definition_scope.with_cte(table) : definition_scope)
          scoped = scoped.with_cte(table)
          names << definition.name
        end
        @body = scoped.prepare(statement.query, outer_scope: outer_scope)
      end

      def columns = @body.columns
      def types = @body.types
      def outer_bindings = @body.outer_bindings
      def constant? = @body.constant?
      def recursive_parts = @body.recursive_parts

      def execute(outer_row = {}, max_rows: nil)
        @body.execute(outer_row, max_rows: max_rows)
      end

      def distinct_if_possible(outer_row)
        @body.distinct_if_possible(outer_row)
      end
    end
  end
end

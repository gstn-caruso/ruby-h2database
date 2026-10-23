# frozen_string_literal: true

module H2
  module SQL
    class StaticTypes
      def initialize(context, parameter_count)
        parameters = Array.new(parameter_count, UNBOUND_PARAMETER)
        @evaluator = Evaluator.new(parameters, queries: Queries.new({}, parameters, context: context))
      end

      def unnest_type(node)
        type = type_of(node)
        return type if type&.name == "JSON"

        type.is_a?(ArrayType) ? type.element_type : Type.new("NULL", nil, nil)
      end

      private

      def type_of(node)
        case node
        when Literal, TypedLiteral, DecimalLiteral, Cast then @evaluator.type_of(node)
        when RowConstructor, ArrayConstructor
          types = node.expressions.map { type_of(it) }
          return nil if types.any?(&:nil?)

          node.is_a?(RowConstructor) ? RowType.new(types) : ArrayType.new(ArrayType.element_common(types), types.length)
        when Subquery
          query = node.query
          if query.is_a?(Values) || (query.is_a?(Select) && !query.source)
            return @evaluator.type_of(node) if @evaluator.constant_expression?(node)
          end
          nil
        end
      end
    end
  end
end

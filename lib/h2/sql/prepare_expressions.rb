# frozen_string_literal: true

module H2
  module SQL
    class PrepareExpressions
      def initialize(context, parameter_count)
        parameters = Array.new(parameter_count, UNBOUND_PARAMETER)
        @evaluator = Evaluator.new(parameters, queries: Queries.new({}, parameters, context: context))
      end

      def prepare(node)
        return node.map { prepare(it) } if node.is_a?(Array)
        return node.with(default: prepare(node.default)) if node.is_a?(Column)
        return node unless node.is_a?(Data) && node.class.name.start_with?("H2::SQL::")
        return node if node.is_a?(TypedLiteral) || node.is_a?(CapturedExpression)

        if node.is_a?(CaseExpression) && closed?(node) && relevant?(node)
          choice, = @evaluator.prepared_case(node)
          return prepare(choice) unless choice.is_a?(CaseExpression)
        end
        node = node.with(**node.to_h.transform_values { prepare(it) })
        if (node.is_a?(ArrayConstructor) || node.is_a?(ArrayElement) ||
            (node.is_a?(Function) && ArrayFunctions::ARITIES.key?(node.name))) && statically_typed?(node)
          @evaluator.validate(node)
        end
        if node.is_a?(Cast) && foldable?(node.expression) && relevant?(node) && !foldable?(node)
          @evaluator.evaluate(node)
        end
        return node unless foldable?(node) && relevant?(node)

        @evaluator.validate(node)
        type = @evaluator.type_of(node)
        value = @evaluator.evaluate(node)
        cast = (value.nil? && type.name != "NULL") || (node.is_a?(Cast) && Temporal::NAMES.include?(type.name) && type.name != "DATE" && type.scale != 9)
        if node.is_a?(Cast) && type.is_a?(ArrayType) && value
          cast = type.precision != value.values.length || type.element_type != value.element_type
        elsif node.is_a?(Cast) && type.name == "VARCHAR" && relevant?(node.expression)
          cast = type.precision != value.to_s.length
        end
        if !node.is_a?(Cast) && Temporal.value?(value)
          type = Temporal.type(Temporal.name(value), 9)
        end
        TypedLiteral.new(value, type, cast)
      end

      private

      def children(node)
        return [node.operand, *node.branches.flatten, node.fallback].compact if node.is_a?(CaseExpression)

        @evaluator.children(node)
      end

      def closed?(node)
        return false if [ColumnRef, BoundColumn, Parameter, CurrentDateTime, Subquery, Exists, InQuery, ArrayQuery, Star].any? { node.is_a?(it) }

        children(node).all? { closed?(it) }
      end

      def statically_typed?(node)
        return false if [ColumnRef, BoundColumn, Subquery, Exists, InQuery, ArrayQuery, Star].any? { node.is_a?(it) }

        children(node).all? { statically_typed?(it) }
      end

      def foldable?(node)
        case node
        when Literal, TypedLiteral, DecimalLiteral then true
        when Cast
          return false unless foldable?(node.expression)

          source = @evaluator.type_of(node.expression)
          (!Temporal::NAMES.include?(source.name) ||
            !@evaluator.session_dependent?(node))
        when TimeZoneExpression
          !node.zone.nil? && children(node).all? { foldable?(it) } &&
            @evaluator.type_of(node.expression).name.end_with?("WITH TIME ZONE")
        when Unary, Binary, Predicate, RowConstructor, ArrayConstructor, ArrayElement
          children(node).all? { foldable?(it) }
        when Function
          Evaluator::FUNCTIONS.key?(node.name) && !Evaluator::AGGREGATES.include?(node.name) &&
            node.arguments.all? { foldable?(it) }
        else false
        end
      end

      def relevant?(node)
        return true if node.is_a?(Function) && ArrayFunctions::ARITIES.key?(node.name)
        return true if node.is_a?(ArrayConstructor) || node.is_a?(ArrayElement)
        return true if node.is_a?(Literal) && node.value.is_a?(ArrayValue)
        return true if node.is_a?(Cast) && node.type.is_a?(ArrayType)
        return true if node.is_a?(Cast) && node.type.name.end_with?("WITH TIME ZONE")
        return true if node.is_a?(Literal) && Temporal.zoned?(node.value)
        return true if node.is_a?(TypedLiteral)
        return true if closed?(node) && @evaluator.session_dependent?(node)

        children(node).any? { relevant?(it) }
      end
    end
  end
end

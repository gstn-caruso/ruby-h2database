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
        return node if node.is_a?(Ordering)

        if node.is_a?(WhenPredicate)
          predicate = node.predicate.with(**node.predicate.to_h.transform_values { prepare(it) })
          return node.with(predicate: predicate)
        end
        return prepare_case(node) if node.is_a?(CaseExpression)
        node = node.with(**node.to_h.transform_values { prepare(it) })
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name) && statically_typed?(node)
          @evaluator.validate(node)
          expression = @evaluator.prepared_math(node).first
          return prepare(expression) unless expression == node
        end
        if node.is_a?(Unary) && node.operator == "NOT"
          child = node.operand
          if child.is_a?(QuantifiedArray)
            node = child.with(operator: QuantifiedComparisons::INVERSE.fetch(child.operator), all: !child.all)
          elsif child.is_a?(InQuery)
            node = child.with(negated: !child.negated)
          elsif child.is_a?(JsonPredicate) || child.is_a?(TypePredicate)
            node = child.with(negated: !child.negated)
          end
        end
        if node.is_a?(QuantifiedArray) && closed?(node) && @evaluator.constant_expression?(node)
          @evaluator.validate(node)
          value = @evaluator.evaluate(node)
          return TypedLiteral.new(value, Type.new("BOOLEAN", nil, nil), value.nil?)
        end
        if node.is_a?(Binary) && %w[+ - * /].include?(node.operator) && closed?(node) && foldable?(node)
          @evaluator.validate(node)
          optimized = @evaluator.optimized_expression(node)
          return optimized unless optimized == node
        end
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
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
          return MathFunctions.literal(value, type)
        end
        if node.is_a?(Function) && %w[COALESCE IFNULL].include?(node.name) && value.is_a?(BigDecimal)
          return NumericOperations.literal(value, type)
        end
        cast = (value.nil? && type.name != "NULL") || (node.is_a?(Cast) && Temporal::NAMES.include?(type.name) && type.name != "DATE" && type.scale != 9)
        if node.is_a?(Cast) && type.is_a?(ArrayType) && value
          cast = type.precision != value.values.length || type.element_type != value.element_type
        elsif node.is_a?(Cast) && type.name == "VARCHAR"
          cast = type.precision != CharacterString.sort_key(value.to_s).bytesize / 2
        elsif node.is_a?(Cast) && %w[BINARY VARBINARY].include?(type.name) && @evaluator.type_of(node.expression).name == "JSON"
          cast = value.nil? || type.name == "BINARY" || type.precision != value.bytesize
        end
        if node.is_a?(Cast) && !value.nil?
          if type.name == "NUMERIC"
            literal = NumericOperations.literal(value, type)
            return literal if literal.precision == type.precision && literal.scale == type.scale && !type.declared_name

            cast = true
          elsif %w[REAL DOUBLE].include?(type.name)
            type = Type.new(type.name, type.name == "REAL" ? 24 : 53, nil)
          end
        end
        if !node.is_a?(Cast) && Temporal.value?(value)
          type = Temporal.type(Temporal.name(value), 9)
        end
        return Literal.new(value) if value.is_a?(DecfloatValue) && !node.is_a?(Cast)
        operands = if node.is_a?(Function) && node.name == "MOD"
          node.arguments
        elsif node.is_a?(Binary) && node.operator == "%"
          [node.left, node.right]
        end
        if value.is_a?(BigDecimal) && operands && Type.common(operands.map { @evaluator.type_of(it) }).name == "DECFLOAT"
          return NumericOperations.literal(value, Type.new("NUMERIC", nil, [value.scale, 0].max))
        end

        TypedLiteral.new(value, type, cast)
      end

      private

      def prepare_case(node)
        operand = node.operand && prepare(node.operand)
        choose = !operand || compile_constant?(operand)
        value = @evaluator.evaluate(operand) if operand && choose
        branches = []
        node.branches.each_with_index do |(condition, result), index|
          condition = prepare(condition)
          result = prepare(result) unless operand
          matched = false
          if choose
            if compile_constant?(condition)
              candidate = @evaluator.evaluate(condition)
              Type.check_comparable(@evaluator.type_of(operand), @evaluator.type_of(condition)) if operand
              matched = operand ? @evaluator.equals(value, candidate) == true : @evaluator.boolean(candidate) == true
            else
              choose = false
            end
          end
          result = prepare(result) if operand
          branches << [condition, result]
          if matched
            return simplify_case(node.with(operand: operand, branches: branches + node.branches.drop(index + 1)))
          end
        end
        simplify_case(node.with(operand: operand, branches: branches, fallback: prepare(node.fallback)))
      end

      def simplify_case(result)
        if closed?(result)
          expression, type = @evaluator.prepared_case(result)
          if expression.is_a?(Literal) && expression.value.nil? && type.name != "NULL"
            return TypedLiteral.new(nil, type, true)
          end
          return expression unless expression.is_a?(CaseExpression)
        end
        result
      end

      def compile_constant?(node)
        closed?(node) && foldable?(node) && @evaluator.constant_expression?(node)
      end

      def children(node)
        return [node.operand, *node.branches.flatten, node.fallback].compact if node.is_a?(CaseExpression)

        @evaluator.children(node)
      end

      def closed?(node)
        return false if [ColumnRef, BoundColumn, Parameter, CurrentDateTime, Subquery, Exists, InQuery, ArrayQuery, Aggregate, Star, WhenPredicate].any? { node.is_a?(it) }

        children(node).all? { closed?(it) }
      end

      def statically_typed?(node)
        return false if [ColumnRef, BoundColumn, Subquery, Exists, InQuery, ArrayQuery, Aggregate, Star].any? { node.is_a?(it) }

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
        when Unary, Binary, Predicate, RowConstructor, ArrayConstructor, ArrayElement, QuantifiedArray,
          JsonFormat, JsonPredicate, TypePredicate, JsonConstructor
          children(node).all? { foldable?(it) }
        when Function
          Evaluator::FUNCTIONS.key?(node.name) && !Evaluator::AGGREGATES.include?(node.name) &&
            node.arguments.all? { foldable?(it) }
        else false
        end
      end

      def relevant?(node)
        return true if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
        return true if node.is_a?(Function) && node.name == "SIGN"
        return true if node.is_a?(Literal) && (node.value.is_a?(JsonValue) || node.value.is_a?(DecfloatValue))
        return true if [JsonFormat, JsonPredicate, TypePredicate, JsonConstructor].any? { node.is_a?(it) }
        return true if node.is_a?(Cast) && node.type.name == "JSON"
        return true if node.is_a?(Cast) && (%w[NUMERIC REAL DOUBLE BOOLEAN DECFLOAT] + Type::INTEGER_LIMITS.keys).include?(node.type.name)
        return true if node.is_a?(Cast) && node.type.name == "CHAR"
        return true if node.is_a?(Cast) && node.type.name == "VARCHAR"
        return true if node.is_a?(Cast) && node.type.name == "NULL"
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

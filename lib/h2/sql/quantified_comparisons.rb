# frozen_string_literal: true

module H2
  module SQL
    module QuantifiedComparisons
      INVERSE = {"=" => "<>", "<>" => "=", "!=" => "=", "<" => ">=", ">" => "<=", "<=" => ">", ">=" => "<",
        "IS DISTINCT FROM" => "IS NOT DISTINCT FROM", "IS NOT DISTINCT FROM" => "IS DISTINCT FROM"}.freeze

      module_function

      def evaluate(left, values, operator, all, evaluator, left_type, right_type)
        return all if values.empty?
        return nil if !operator.start_with?("IS") && evaluator.contains_null?(left)

        unknown = false
        values.each do |right|
          result = compare(left, right, operator, evaluator, left_type, right_type)
          return !all if result == !all

          unknown = true if result.nil?
        end
        unknown ? nil : all
      end

      def compare(left, right, operator, evaluator, left_type, right_type)
        total = operator.start_with?("IS")
        equality = total || ["=", "<>", "!="].include?(operator)
        result = ordering(left, right, equality, total, evaluator, left_type, right_type)
        return nil if result.nil?

        case operator
        when "=", "IS NOT DISTINCT FROM" then result.zero?
        when "<>", "!=", "IS DISTINCT FROM" then !result.zero?
        when "<" then result.negative?
        when ">" then result.positive?
        when "<=" then result <= 0
        when ">=" then result >= 0
        end
      end

      def ordering(left, right, equality, total, evaluator, left_type, right_type)
        return total ? evaluator.compare(left, right) : nil if left.nil? || right.nil?

        a, b = collection?(left), collection?(right)
        if a || b
          if !total && a && left.class != right.class
            raise Error.new(22018, "Collection comparison requires matching value types")
          end
          if left.is_a?(RowValue) || right.is_a?(RowValue)
            left = RowValue.new([left]) unless left.is_a?(RowValue)
            right = RowValue.new([right]) unless right.is_a?(RowValue)
            left_type = RowType.new([left_type]) unless left_type.is_a?(RowType)
            right_type = RowType.new([right_type]) unless right_type.is_a?(RowType)
            raise Error.new(21002, "Row column counts do not match") unless left.values.length == right.values.length
          else
            left = ArrayValue.new([left], left_type) unless a
            right = ArrayValue.new([right], right_type) unless b
            left_type = ArrayType.new(left_type, 1) unless left_type.is_a?(ArrayType)
            right_type = ArrayType.new(right_type, 1) unless right_type.is_a?(ArrayType)
          end
          return collections(left, right, equality, total || !a, evaluator, left_type, right_type)
        end
        left_type = evaluator.type_of(Literal.new(left)) if %w[NULL UNKNOWN].include?(left_type.name)
        right_type = evaluator.type_of(Literal.new(right)) if %w[NULL UNKNOWN].include?(right_type.name)
        type = Type.common([left_type, right_type])
        type = Type.new("CHAR", nil, nil) if %w[CHAR VARCHAR].include?(type.name) && [left_type, right_type].any? { it.name == "CHAR" }
        evaluator.compare(type.coerce(left, source_type: left_type, context: evaluator.context),
          type.coerce(right, source_type: right_type, context: evaluator.context))
      end

      def collections(left, right, equality, total, evaluator, left_type, right_type)
        width = left.values.length <=> right.values.length
        return width if equality && !total && !width.zero?

        unknown = false
        [left.values.length, right.values.length].min.times do |index|
          a, b = left.values[index], right.values[index]
          result = ordering(a, b, equality, total, evaluator, component_type(left_type, a, index, evaluator), component_type(right_type, b, index, evaluator))
          return nil if result.nil? && !equality
          return result if result && !result.zero?

          unknown = true if result.nil?
        end
        unknown ? nil : width
      end

      def collection?(value)
        value.is_a?(ArrayValue) || value.is_a?(RowValue)
      end

      def component_type(type, value, index, evaluator)
        return type.element_type if type.is_a?(ArrayType)
        return type.fields[index] if type.is_a?(RowType)

        evaluator.type_of(Literal.new(value))
      end
    end
  end
end

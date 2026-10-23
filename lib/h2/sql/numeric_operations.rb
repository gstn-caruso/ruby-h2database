# frozen_string_literal: true

module H2
  module SQL
    module NumericOperations
      module_function

      def type(operator, left, right)
        if Type.common([left, right]).name == "DECFLOAT"
          precisions = [left, right].map { Type.decfloat_precision(it) }
          precision = operator == "*" ? precisions.sum : precisions.max + 1
          return Type.new("DECFLOAT", [precision, 100_000].min, 0)
        end
        p1, s1 = Type.numeric_info(left)
        p2, s2 = Type.numeric_info(right)
        case operator
        when "+", "-"
          scale = [s1, s2].max
          precision = [p1 + scale - s1, p2 + scale - s2].max + 1
        when "*"
          precision, scale = p1 + p2, s1 + s2
        when "/"
          scale = [[s1 - s2 + p2 * 2, 0].max, 100_000].min
          precision = p1 + s2 - s1 + scale
          reduction = [[precision - 100_000, 0].max, scale].min
          precision -= reduction
          scale -= reduction
        else
          return Type.common([left, right])
        end
        Type.new("NUMERIC", [precision, 100_000].min, [scale, 100_000].min)
      end

      def divide(left, right, scale)
        ratio = left.to_r / right.to_r
        scaled = ratio.abs * 10**scale
        integer, remainder = scaled.numerator.divmod(scaled.denominator)
        integer += 1 if remainder * 2 > scaled.denominator
        integer = -integer if ratio.negative?
        BigDecimal(integer.to_s) * BigDecimal("1E-#{scale}")
      end

      def modulus_type(types)
        common = Type.common(types)
        return Type.new("BIGINT", nil, 0) if common.name == "NULL"
        raise Error.new(50004, "MOD argument types are unknown") if common.name == "UNKNOWN"
        raise Error.new(90008, "MOD requires numeric arguments") unless (Type::INTEGER_LIMITS.keys + %w[NUMERIC REAL DOUBLE DECFLOAT]).include?(common.name)

        divisor = types.last
        (Type::INTEGER_LIMITS.keys + %w[NUMERIC REAL DOUBLE DECFLOAT]).include?(divisor.name) ? divisor : common
      end

      def literal(value, type)
        return TypedLiteral.new(nil, type, true) if value.nil?
        return Literal.new(value) if value.is_a?(DecfloatValue)
        type = FloatingOperations.type(type) if value.is_a?(Float) && FloatingOperations::NAMES.include?(type.name)
        return TypedLiteral.new(value, type, false) unless type.name == "NUMERIC"

        digits = ArrayType.decimal_text(value, type.scale).delete('-.').sub(/\A0+/, '')
        DecimalLiteral.new(value, [digits.length, 1].max, type.scale, nil)
      end
    end
  end
end

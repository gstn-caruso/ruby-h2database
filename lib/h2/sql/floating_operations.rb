# frozen_string_literal: true

module H2
  module SQL
    module FloatingOperations
      NAMES = %w[REAL DOUBLE].freeze
      module_function

      def type(input)
        Type.new(input.name, input.name == "REAL" ? 24 : 53, nil)
      end

      def evaluate(operator, common, sources, read)
        left = common.convert(read.call(0), source_type: sources[0])
        right = common.convert(read.call(1), source_type: sources[1])
        return nil if left.nil? || right.nil?

        raise Error.new(22012, "Division by zero") if %w[/ %].include?(operator) && right.zero?

        result = case operator
        when "+" then left + right
        when "-" then left - right
        when "*" then left * right
        when "/" then left / right
        when "%" then remainder(left, right)
        end
        common.convert(result, source_type: common)
      end

      def remainder(left, right)
        return Float::NAN if left.nan? || right.nan? || left.infinite?
        return left if right.infinite? || left.zero?

        a, b = left.to_r, right.to_r
        (a - b * (a / b).truncate).to_f
      end

      def compare(left, right)
        left_nan = left.is_a?(Float) && left.nan?
        right_nan = right.is_a?(Float) && right.nan?
        return 0 if left_nan && right_nan
        return 1 if left_nan
        return -1 if right_nan

        left <=> right
      end

      def comparison_pair(left, right, sources)
        return [left, right] if left.nil? || right.nil? || !sources.all?
        return [left, right] unless sources.any? { NAMES.include?(it.name) }

        common = Type.common(sources)
        return [left, right] unless (NAMES + ['DECFLOAT']).include?(common.name)

        [left, right].zip(sources).map { |value, source| common.coerce(value, source_type: source) }
      end

      def sum(values)
        Type.new("DOUBLE", 53, nil).convert(values.reduce(0.0) { |sum, value| sum + value.to_f })
      end
    end
  end
end

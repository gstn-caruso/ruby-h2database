# frozen_string_literal: true

module H2
  module SQL
    class Evaluator
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      FUNCTIONS = {"COUNT" => 1..1, "SUM" => 1..1, "AVG" => 1..1, "MIN" => 1..1, "MAX" => 1..1,
        "UPPER" => 1..1, "UCASE" => 1..1, "LOWER" => 1..1, "LCASE" => 1..1, "LENGTH" => 1..1, "CHAR_LENGTH" => 1..1,
        "ABS" => 1..1, "COALESCE" => 1..Float::INFINITY, "NULLIF" => 2..2, "MOD" => 2..2}.freeze

      attr_reader :scope

      def initialize(parameters, columns = [], qualifiers = [], scope: nil)
        @parameters = parameters
        @scope = scope || Scope.for_columns(columns, qualifiers)
      end

      def validate(node, aggregates: false, inside_aggregate: false)
        return if node.nil?

        case node
        when ColumnRef
          scope.resolve(node)
        when Literal, Parameter, BoundColumn
          nil
        when Function
          arity = FUNCTIONS[node.name]
          raise Error.new(50100, "Function #{node.name} not yet ported") unless arity
          raise Error.new(7001, "Invalid argument count for #{node.name}") unless arity.cover?(node.arguments.length)

          aggregate = AGGREGATES.include?(node.name)
          if aggregate && (!aggregates || inside_aggregate)
            raise Error.new(90054, "Invalid use of aggregate #{node.name}")
          end
          if node.distinct && !aggregate
            raise Error.new(42000, "DISTINCT requires an aggregate function")
          end
          node.arguments.each do |argument|
            if argument.is_a?(Star) && node.name == "COUNT" && !node.distinct && argument.qualifier.nil?
              next
            end
            validate(argument, aggregates: aggregates, inside_aggregate: inside_aggregate || aggregate)
          end
        when Default, Star
          raise Error.new(42000, "Invalid expression #{node.class.name.split('::').last}")
        else
          children(node).each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
        end
      end

      def contains_aggregate?(node)
        return false unless node
        return true if node.is_a?(Function) && AGGREGATES.include?(node.name)

        children(node).any? { contains_aggregate?(it) }
      end

      def validate_grouping(node, groups)
        return unless node
        return if groups.any? { canonical(it) == canonical(node) }
        return if node.is_a?(Function) && AGGREGATES.include?(node.name)

        if node.is_a?(ColumnRef) || node.is_a?(BoundColumn)
          name = node.is_a?(BoundColumn) ? node.binding.name : node.name
          raise Error.new(90016, "Column #{name} must be in GROUP BY")
        end

        children(node).each { validate_grouping(it, groups) }
      end

      def evaluate(node, row = {}, group = nil)
        case node
        when Literal then node.value
        when Parameter then @parameters.fetch(node.index)
        when ColumnRef then row.fetch(scope.resolve(node).key)
        when BoundColumn then row.fetch(node.binding.key)
        when Unary
          value = evaluate(node.operand, row, group)
          return nil if value.nil?

          case node.operator
          when "NOT" then !boolean(value)
          when "+" then numeric(value)
          when "-" then check_integer(-numeric(value), node)
          end
        when Binary then binary(node, row, group)
        when Predicate then predicate(node, row, group)
        when Cast then node.type.convert(evaluate(node.expression, row, group), cast: true)
        when Function then function(node, row, group)
        else raise Error.new(42000, "Invalid expression")
        end
      end

      def boolean(value)
        Type.new("BOOLEAN", nil, nil).convert(value)
      end

      def compare(left, right)
        if left.is_a?(Numeric) || right.is_a?(Numeric)
          left = numeric(left)
          right = numeric(right)
        elsif [true, false].include?(left) || [true, false].include?(right)
          left = boolean(left) ? 1 : 0
          right = boolean(right) ? 1 : 0
        end
        result = left <=> right
        raise Error.new(22018, "Cannot compare #{left.inspect} and #{right.inspect}") if result.nil?

        result
      end

      def type_of(node)
        case node
        when ColumnRef then scope.resolve(node).type
        when BoundColumn then node.binding.type
        when Cast then node.type
        when Parameter then type_of(Literal.new(@parameters.fetch(node.index)))
        when Literal
          case node.value
          when Integer
            name = if Type::INTEGER_LIMITS.fetch("INTEGER").cover?(node.value)
              "INTEGER"
            elsif Type::INTEGER_LIMITS.fetch("BIGINT").cover?(node.value)
              "BIGINT"
            else
              "NUMERIC"
            end
            Type.new(name, nil, 0)
          when BigDecimal then Type.new("NUMERIC", nil, [node.value.scale, 0].max)
          when Float then Type.new("DOUBLE", nil, nil)
          when String then Type.new("VARCHAR", node.value.length, nil)
          when true, false then Type.new("BOOLEAN", nil, nil)
          when nil then Type.new("NULL", nil, nil)
          end
        when Unary then node.operator == "NOT" ? Type.new("BOOLEAN", nil, nil) : type_of(node.operand)
        when Predicate then Type.new("BOOLEAN", nil, nil)
        when Function then function_type(node)
        when Binary
          return Type.new("BOOLEAN", nil, nil) if %w[AND OR = <> != < > <= >=].include?(node.operator)
          return Type.new("VARCHAR", nil, nil) if node.operator == "||"

          types = [type_of(node.left), type_of(node.right)]
          type = Type.common(types)
          if node.operator == "*" && type.name == "NUMERIC"
            type = type.with(scale: types.compact.sum { it.scale || 0 })
          end
          type
        end
      end

      def children(node)
        case node
        when Unary then [node.operand]
        when Binary then [node.left, node.right]
        when Predicate, Function then node.arguments
        when Cast then [node.expression]
        else []
        end
      end

      private

      def canonical(node)
        case node
        when ColumnRef then BoundColumn.new(scope.resolve(node))
        when Unary then node.with(operand: canonical(node.operand))
        when Binary then node.with(left: canonical(node.left), right: canonical(node.right))
        when Predicate, Function then node.with(arguments: node.arguments.map { canonical(it) })
        when Cast then node.with(expression: canonical(node.expression))
        else node
        end
      end

      def function_type(node)
        argument_type = type_of(node.arguments.first)
        case node.name
        when "COUNT", "LENGTH", "CHAR_LENGTH" then Type.new("BIGINT", nil, 0)
        when "UPPER", "UCASE", "LOWER", "LCASE" then Type.new("VARCHAR", nil, nil)
        when "ABS", "MIN", "MAX", "NULLIF" then argument_type
        when "COALESCE" then Type.common(node.arguments.map { type_of(it) })
        when "MOD" then type_of(node.arguments.last)
        when "SUM"
          return nil unless argument_type
          case argument_type.name
          when "TINYINT", "SMALLINT", "INTEGER" then Type.new("BIGINT", nil, 0)
          when "BIGINT" then Type.new("NUMERIC", 100_000, 0)
          else argument_type
          end
        when "AVG"
          if argument_type && %w[BIGINT NUMERIC].include?(argument_type.name)
            Type.new("NUMERIC", 100_000, (argument_type.scale || 0) + 10)
          else
            Type.new("DOUBLE", nil, nil)
          end
        end
      end

      def numeric(value)
        return value if value.is_a?(Numeric)
        return value ? 1 : 0 if value == true || value == false

        BigDecimal(value.to_s)
      rescue ArgumentError
        raise Error.new(22018, "Cannot convert #{value.inspect} to number")
      end

      def check_integer(value, node)
        type = type_of(node)
        return value unless value.is_a?(Integer) && type && Type::INTEGER_LIMITS.key?(type.name)

        type.convert(value)
      end

      def binary(node, row, group)
        left = evaluate(node.left, row, group)
        right = evaluate(node.right, row, group)
        if node.operator == "AND"
          left, right = boolean(left), boolean(right)
          return false if left == false || right == false
          return nil if left.nil? || right.nil?

          return true
        elsif node.operator == "OR"
          left, right = boolean(left), boolean(right)
          return true if left == true || right == true
          return nil if left.nil? || right.nil?

          return false
        end
        return nil if left.nil? || right.nil?

        case node.operator
        when "=" then compare(left, right).zero?
        when "<>", "!=" then !compare(left, right).zero?
        when "<" then compare(left, right).negative?
        when ">" then compare(left, right).positive?
        when "<=" then compare(left, right) <= 0
        when ">=" then compare(left, right) >= 0
        when "||" then (left.to_s + right.to_s).freeze
        else
          left, right = numeric(left), numeric(right)
          if %w[/ %].include?(node.operator) && right.zero?
            raise Error.new(22012, "Division by zero")
          end
          value = case node.operator
          when "+" then left + right
          when "-" then left - right
          when "*" then left * right
          when "/"
            if left.is_a?(Integer) && right.is_a?(Integer)
              (left.negative? ^ right.negative? ? -1 : 1) * (left.abs / right.abs)
            else
              left / right
            end
          when "%" then left.remainder(right)
          end
          check_integer(value, node)
        end
      end

      def predicate(node, row, group)
        values = node.arguments.map { evaluate(it, row, group) }
        left, right, extra = values
        case node.operator
        when :is then right.nil? ? left.nil? : boolean(left) == right
        when :distinct, :not_distinct
          equal = if left.nil? || right.nil?
            left.nil? && right.nil?
          else
            compare(left, right).zero?
          end
          node.operator == :not_distinct ? equal : !equal
        when :between
          low = left.nil? || right.nil? ? nil : compare(left, right) >= 0
          high = left.nil? || extra.nil? ? nil : compare(left, extra) <= 0
          return false if low == false || high == false

          low.nil? || high.nil? ? nil : true
        when :in
          return nil if left.nil?

          candidates = values.drop(1)
          return true if candidates.compact.any? { compare(left, it).zero? }

          candidates.include?(nil) ? nil : false
        when :like
          return nil if values.any?(&:nil?)
          raise Error.new(22025, "ESCAPE must be zero or one character") unless extra.is_a?(String) && extra.length <= 1

          like(left.to_s, right.to_s, extra)
        end
      end

      def like(value, pattern, escape)
        regex = +"\\A"
        escaped = false
        pattern.each_char do |char|
          if escaped
            raise Error.new(22025, "Invalid LIKE escape") unless [escape, "%", "_"].include?(char)

            regex << Regexp.escape(char)
            escaped = false
          elsif !escape.empty? && char == escape
            escaped = true
          else
            regex << {"%" => ".*", "_" => "."}.fetch(char) { Regexp.escape(char) }
          end
        end
        raise Error.new(22025, "Incomplete LIKE escape") if escaped

        Regexp.new(regex + "\\z", Regexp::MULTILINE).match?(value)
      end

      def function(node, row, group)
        return aggregate(node, group) if AGGREGATES.include?(node.name)

        if node.name == "COALESCE"
          node.arguments.each do |argument|
            value = evaluate(argument, row, group)
            return value unless value.nil?
          end
          return nil
        end
        values = node.arguments.map { evaluate(it, row, group) }
        first, second = values
        if node.name == "NULLIF"
          return nil if !first.nil? && !second.nil? && compare(first, second).zero?

          return first
        end
        return nil if values.any?(&:nil?)

        case node.name
        when "UPPER", "UCASE" then first.to_s.upcase.freeze
        when "LOWER", "LCASE" then first.to_s.downcase.freeze
        when "LENGTH", "CHAR_LENGTH" then first.to_s.length
        when "ABS" then check_integer(numeric(first).abs, node)
        when "MOD"
          raise Error.new(22012, "Division by zero") if numeric(second).zero?

          numeric(first).remainder(numeric(second))
        end
      end

      def aggregate(node, group)
        argument = node.arguments.first
        return group.size if argument.is_a?(Star)

        values = group.map { evaluate(argument, it) }.compact
        values = values.uniq if node.distinct
        return values.length if node.name == "COUNT"
        return nil if values.empty?

        case node.name
        when "SUM" then values.sum { numeric(it) }
        when "AVG"
          type = type_of(argument)
          if type && %w[BIGINT NUMERIC].include?(type.name)
            sum = values.sum { BigDecimal(numeric(it).to_s) }
            sum.div(BigDecimal(values.length.to_s), [sum.precision + 20, 40].max)
              .round((type.scale || 0) + 10, BigDecimal::ROUND_HALF_DOWN)
          else
            values.sum { numeric(it).to_f } / values.length
          end
        when "MIN" then values.min { compare(_1, _2) }
        when "MAX" then values.max { compare(_1, _2) }
        end
      end
    end
  end
end

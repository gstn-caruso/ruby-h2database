# frozen_string_literal: true

module H2
  module SQL
    class Evaluator
      AGGREGATES = %w[COUNT SUM AVG MIN MAX].freeze
      FUNCTIONS = {"COUNT" => 1..1, "SUM" => 1..1, "AVG" => 1..1, "MIN" => 1..1, "MAX" => 1..1,
        "UPPER" => 1..1, "UCASE" => 1..1, "LOWER" => 1..1, "LCASE" => 1..1, "LENGTH" => 1..1, "CHAR_LENGTH" => 1..1,
        "OCTET_LENGTH" => 1..1, "BIT_LENGTH" => 1..1,
        "ABS" => 1..1, "COALESCE" => 1..Float::INFINITY, "NULLIF" => 2..2, "MOD" => 2..2}.freeze

      attr_reader :scope, :outer_bindings

      def initialize(parameters, columns = [], qualifiers = [], scope: nil, queries: nil)
        @parameters = parameters
        @scope = scope || Scope.for_columns(columns, qualifiers)
        @queries = queries
        @subqueries = {}
        @outer_bindings = []
        @group_correlations = []
        @cases = {}
      end

      def validate(node, aggregates: false, inside_aggregate: false)
        return if node.nil?

        case node
        when ColumnRef
          binding = scope.resolve(node)
          @outer_bindings << binding unless scope.local?(binding) || @outer_bindings.include?(binding)
        when Literal, Parameter, BoundColumn
          nil
        when CaseExpression
          expression, _type = prepared_case(node)
          expressions = expression.is_a?(CaseExpression) ? case_children(expression) : [expression]
          expressions.each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
        when Subquery, Exists, InQuery
          validate(node.expression, aggregates: aggregates, inside_aggregate: inside_aggregate) if node.is_a?(InQuery)
          plan = subquery_plan(node)
          Type.check_comparable(type_of(node.expression), query_type(plan)) if node.is_a?(InQuery)
          plan.outer_bindings.each do |binding|
            @outer_bindings << binding unless scope.local?(binding) || @outer_bindings.include?(binding)
          end
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
          if %w[SUM AVG].include?(node.name) && %w[BINARY VARBINARY UUID].include?(type_of(node.arguments.first)&.name)
            raise Error.new(90015, "Invalid type for #{node.name}")
          end
        when Default, Star
          raise Error.new(42000, "Invalid expression #{node.class.name.split('::').last}")
        else
          children(node).each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
          if node.is_a?(Binary) && %w[= <> != < > <= >=].include?(node.operator)
            Type.check_comparable(type_of(node.left), type_of(node.right))
          elsif node.is_a?(Binary) && %w[+ - * / %].include?(node.operator)
            type = Type.common([type_of(node.left), type_of(node.right)])
            if %w[BINARY VARBINARY UUID].include?(type.name)
              raise Error.new(50100, "Arithmetic on #{type.name}")
            end
          elsif node.is_a?(Predicate) && [:in, :between, :distinct, :not_distinct].include?(node.operator)
            node.arguments.drop(1).each { Type.check_comparable(type_of(node.arguments.first), type_of(it)) }
          end
        end
      end

      def contains_aggregate?(node)
        return false unless node
        return true if node.is_a?(Function) && AGGREGATES.include?(node.name)

        children(node).any? { contains_aggregate?(it) }
      end

      def contains_subquery?(node)
        return true if node.is_a?(Subquery) || node.is_a?(Exists) || node.is_a?(InQuery)

        children(node).any? { contains_subquery?(it) }
      end

      def validate_grouping(node, groups)
        return unless node
        return if groups.any? { canonical(it) == canonical(node) }
        return if node.is_a?(Function) && AGGREGATES.include?(node.name)
        if node.is_a?(Subquery) || node.is_a?(Exists) || node.is_a?(InQuery)
          subquery_plan(node).outer_bindings.each do |binding|
            @group_correlations << binding if scope.local?(binding) && !@group_correlations.include?(binding)
          end
          validate_grouping(node.expression, groups) if node.is_a?(InQuery)
          return
        end

        if node.is_a?(ColumnRef) || node.is_a?(BoundColumn)
          binding = node.is_a?(BoundColumn) ? node.binding : scope.resolve(node)
          return unless scope.local?(binding)

          name = node.is_a?(BoundColumn) ? node.binding.name : node.name
          raise Error.new(90016, "Column #{name} must be in GROUP BY")
        end

        children(node).each { validate_grouping(it, groups) }
      end

      def validate_group_correlations(group)
        return if @group_correlations.empty?

        first = group.first
        return unless first

        group.each do |row|
          @group_correlations.each do |binding|
            unless equals(first.fetch(binding.key), row.fetch(binding.key), null_safe: true)
              raise Error.new(90016, "Correlated column #{binding.name} must be constant in its group")
            end
          end
        end
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
        when Cast then node.type.convert(evaluate(node.expression, row, group), cast: true, source_type: type_of(node.expression))
        when Function then function(node, row, group)
        when RowConstructor then RowValue.new(node.expressions.map { evaluate(it, row, group) })
        when Subquery
          plan = subquery_plan(node)
          result = plan.execute(row, max_rows: 2)
          raise Error.new(90053, "Scalar subquery contains more than one row") if result.rows.length > 1

          values = result.rows.first || Array.new(plan.columns.length)
          values.length == 1 ? values.first : RowValue.new(values)
        when Exists then !subquery_plan(node).execute(row, max_rows: 1).rows.empty?
        when InQuery
          value = evaluate(node.expression, row, group)
          plan = subquery_plan(node)
          values = plan.execute(row).rows.map { it.length == 1 ? it.first : RowValue.new(it) }
          return false if values.empty?
          return nil if contains_null?(value)
          if plan.columns.length == 1 && value.is_a?(RowValue)
            value = value.values.first
          end
          return true if values.any? { equals(value, it) == true }

          values.any? { contains_null?(it) } ? nil : false
        when CaseExpression
          expression, type = prepared_case(node)
          return type.convert(evaluate(expression, row, group), cast: true) unless expression.is_a?(CaseExpression)

          operand = evaluate(expression.operand, row, group) if expression.operand
          branch = expression.branches.find do |condition, _value|
            candidate = evaluate(condition, row, group)
            expression.operand ? equals(operand, candidate) == true : boolean(candidate) == true
          end
          value = evaluate(branch ? branch.last : expression.fallback, row, group)
          type.convert(value, cast: true)
        else raise Error.new(42000, "Invalid expression")
        end
      end

      def boolean(value)
        Type.new("BOOLEAN", nil, nil).convert(value)
      end

      def compare(left, right)
        return 0 if left.nil? && right.nil?
        return -1 if left.nil?
        return 1 if right.nil?
        if left.is_a?(RowValue) || right.is_a?(RowValue)
          left, right = row_pair(left, right)
          left.values.zip(right.values).each do |a, b|
            comparison = compare(a, b)
            return comparison unless comparison.zero?
          end
          return 0
        end
        if left.is_a?(UUIDValue) || right.is_a?(UUIDValue)
          Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          uuid = Type.new("UUID", nil, nil)
          return uuid.convert(left) <=> uuid.convert(right)
        elsif BinaryString.binary?(left) || BinaryString.binary?(right)
          Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          return left.b <=> right.b
        end
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

      def equals(left, right, null_safe: false)
        return null_safe ? left.nil? && right.nil? : nil if left.nil? || right.nil?
        if left.is_a?(RowValue) || right.is_a?(RowValue)
          left, right = row_pair(left, right)
          results = left.values.zip(right.values).map { |a, b| equals(a, b, null_safe: null_safe) }
          return false if results.include?(false)
          return nil if results.include?(nil)

          return true
        end
        compare(left, right).zero?
      end

      def type_of(node)
        case node
        when ColumnRef then scope.resolve(node).type
        when BoundColumn then node.binding.type
        when Cast then node.type
        when RowConstructor then RowType.new(node.expressions.map { type_of(it) })
        when Subquery then query_type(subquery_plan(node))
        when Exists, InQuery then Type.new("BOOLEAN", nil, nil)
        when CaseExpression then prepared_case(node).last
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
          when String then Type.new(BinaryString.binary?(node.value) ? "VARBINARY" : "VARCHAR", node.value.length, nil)
          when UUIDValue then Type.new("UUID", nil, nil)
          when true, false then Type.new("BOOLEAN", nil, nil)
          when nil then Type.new("NULL", nil, nil)
          when RowValue then RowType.new(node.value.values.map { type_of(Literal.new(it)) })
          end
        when Unary then node.operator == "NOT" ? Type.new("BOOLEAN", nil, nil) : type_of(node.operand)
        when Predicate then Type.new("BOOLEAN", nil, nil)
        when Function then function_type(node)
        when Binary
          return Type.new("BOOLEAN", nil, nil) if %w[AND OR = <> != < > <= >=].include?(node.operator)
          if node.operator == "||"
            names = [type_of(node.left)&.name, type_of(node.right)&.name]
            return Type.new((names - %w[BINARY VARBINARY NULL]).empty? && (names & %w[BINARY VARBINARY]).any? ? "VARBINARY" : "VARCHAR", nil, nil)
          end

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
        when RowConstructor then node.expressions
        when CaseExpression
          expression = prepared_case(node).first
          expression.is_a?(CaseExpression) ? case_children(expression) : [expression]
        else []
        end
      end

      private

      def case_children(node)
        [node.operand, *node.branches.flatten, node.fallback].compact
      end

      def prepared_case(node)
        @cases.fetch(node) do
          validate(node.operand, aggregates: true) if node.operand
          all_constant = !node.operand || constant?(node.operand)
          operand = evaluate(node.operand) if node.operand && all_constant
          types = []
          node.branches.each do |condition, value|
            validate(condition, aggregates: true)
            validate(value, aggregates: true) unless node.operand
            if all_constant
              if constant?(condition)
                candidate = evaluate(condition)
                matched = node.operand ? equals(operand, candidate) == true : boolean(candidate) == true
                if matched
                  validate(value, aggregates: true)
                  return @cases[node] = [value, type_of(value)]
                end
              else
                all_constant = false
              end
            end
            validate(value, aggregates: true) if node.operand
            types << type_of(value)
          end
          validate(node.fallback, aggregates: true)
          types << type_of(node.fallback)
          if all_constant
            type = node.fallback.is_a?(Literal) && node.fallback.value.nil? ? Type.common(types) : type_of(node.fallback)
            @cases[node] = [node.fallback, type]
          else
            @cases[node] = [node, Type.common(types)]
          end
        end
      end

      def constant?(node)
        case node
        when Literal then true
        when Unary, Binary, Predicate, Cast, RowConstructor then children(node).all? { constant?(it) }
        when Function then FUNCTIONS.key?(node.name) && !AGGREGATES.include?(node.name) && children(node).all? { constant?(it) }
        when CaseExpression
          expression = prepared_case(node).first
          !expression.is_a?(CaseExpression) && constant?(expression)
        else false
        end
      end

      def contains_null?(value)
        value.nil? || (value.is_a?(RowValue) && value.values.any? { contains_null?(it) })
      end

      def subquery_plan(node)
        raise Error.new(50100, "Subquery is not supported in this context") unless @queries

        @subqueries[node] ||= @queries.prepare(node.query, outer_scope: scope)
      end

      def query_type(plan)
        plan.types.length == 1 ? plan.types.first : RowType.new(plan.types)
      end

      def row_pair(left, right)
        left = RowValue.new([left]) unless left.is_a?(RowValue)
        right = RowValue.new([right]) unless right.is_a?(RowValue)
        unless left.values.length == right.values.length
          raise Error.new(21002, "Row column counts do not match")
        end
        [left, right]
      end

      def nullable_compare(left, right)
        return nil if left.nil? || right.nil?
        if left.is_a?(RowValue) || right.is_a?(RowValue)
          left, right = row_pair(left, right)
          left.values.zip(right.values).each do |a, b|
            result = nullable_compare(a, b)
            return result if result.nil? || !result.zero?
          end
          return 0
        end
        compare(left, right)
      end

      def in_values(value, candidates)
        unknown = false
        candidates.each do |candidate|
          result = equals(value, candidate)
          return true if result == true

          unknown = true if result.nil?
        end
        unknown ? nil : false
      end

      def canonical(node)
        case node
        when ColumnRef then BoundColumn.new(scope.resolve(node))
        when Unary then node.with(operand: canonical(node.operand))
        when Binary then node.with(left: canonical(node.left), right: canonical(node.right))
        when Predicate, Function then node.with(arguments: node.arguments.map { canonical(it) })
        when Cast then node.with(expression: canonical(node.expression))
        when RowConstructor then node.with(expressions: node.expressions.map { canonical(it) })
        when CaseExpression
          node.with(operand: node.operand && canonical(node.operand),
            branches: node.branches.map { |condition, value| [canonical(condition), canonical(value)] }, fallback: canonical(node.fallback))
        else node
        end
      end

      def function_type(node)
        argument_type = type_of(node.arguments.first)
        case node.name
        when "COUNT", "LENGTH", "CHAR_LENGTH", "OCTET_LENGTH", "BIT_LENGTH" then Type.new("BIGINT", nil, 0)
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
        if BinaryString.binary?(value) || value.is_a?(UUIDValue)
          raise Error.new(50100, "Numeric operation on binary or UUID values")
        end
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
        if %w[= <> != < > <= >=].include?(node.operator) && (left.is_a?(RowValue) ^ right.is_a?(RowValue))
          raise Error.new(22018, "Cannot compare row and scalar values")
        end

        case node.operator
        when "=" then equals(left, right)
        when "<>", "!="
          result = equals(left, right)
          result.nil? ? nil : !result
        when "<", ">", "<=", ">="
          comparison = nullable_compare(left, right)
          return nil if comparison.nil?

          case node.operator
          when "<" then comparison.negative?
          when ">" then comparison.positive?
          when "<=" then comparison <= 0
          when ">=" then comparison >= 0
          end
        when "||"
          if type_of(node).name == "VARBINARY"
            (left.b + right.b).freeze
          else
            (BinaryString.text(left) + BinaryString.text(right)).freeze
          end
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
        when :is, :is_not
          if right.nil? && left.is_a?(RowValue)
            node.operator == :is ? left.values.all?(&:nil?) : left.values.none?(&:nil?)
          else
            result = right.nil? ? left.nil? : boolean(left) == right
            node.operator == :is_not ? !result : result
          end
        when :distinct, :not_distinct
          equal = equals(left, right, null_safe: true)
          node.operator == :not_distinct ? equal : !equal
        when :between
          lower_comparison = nullable_compare(left, right)
          upper_comparison = nullable_compare(left, extra)
          low = lower_comparison.nil? ? nil : lower_comparison >= 0
          high = upper_comparison.nil? ? nil : upper_comparison <= 0
          return false if low == false || high == false

          low.nil? || high.nil? ? nil : true
        when :in
          in_values(left, values.drop(1))
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
            return function_type(node).convert(value, cast: true, source_type: type_of(argument)) unless value.nil?
          end
          return nil
        end
        values = node.arguments.map { evaluate(it, row, group) }
        first, second = values
        if node.name == "NULLIF"
          return nil if equals(first, second) == true

          return first
        end
        return nil if values.any?(&:nil?)

        case node.name
        when "UPPER", "UCASE" then BinaryString.text(first).upcase.freeze
        when "LOWER", "LCASE" then BinaryString.text(first).downcase.freeze
        when "LENGTH", "CHAR_LENGTH"
          text = BinaryString.text(first)
          if BinaryString.binary?(first)
            first.bytesize
          elsif [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(text.encoding)
            text.bytesize / 2
          else
            text.encode(Encoding::UTF_16BE).bytesize / 2
          end
        when "OCTET_LENGTH", "BIT_LENGTH"
          length = BinaryString.encode(first, source_type: type_of(node.arguments.first)).bytesize
          node.name == "BIT_LENGTH" ? length * 8 : length
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

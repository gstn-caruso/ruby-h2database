# frozen_string_literal: true

module H2
  module SQL
    class Evaluator
      AGGREGATES = Aggregate::NAMES
      FUNCTIONS = {"COUNT" => 1..1, "SUM" => 1..1, "AVG" => 1..1, "MIN" => 1..1, "MAX" => 1..1, "ARRAY_AGG" => 1..1,
        "UPPER" => 1..1, "UCASE" => 1..1, "LOWER" => 1..1, "LCASE" => 1..1, "LENGTH" => 1..1, "CHAR_LENGTH" => 1..1,
        "OCTET_LENGTH" => 1..1, "BIT_LENGTH" => 1..1,
        "ABS" => 1..1, "SIGN" => 1..1, "COALESCE" => 1..Float::INFINITY, "IFNULL" => 2..2, "NULLIF" => 2..2, "MOD" => 2..2,
        "EXTRACT" => 2..2, "DATE_TRUNC" => 2..2, "LAST_DAY" => 1..1, "DATEADD" => 3..3, "DATEDIFF" => 3..3}.merge(ArrayFunctions::ARITIES).merge(MathFunctions::ARITIES).freeze

      attr_reader :scope, :outer_bindings, :context

      def initialize(parameters, columns = [], qualifiers = [], scope: nil, queries: nil)
        @parameters = parameters
        @scope = scope || Scope.for_columns(columns, qualifiers)
        @queries = queries
        @context = queries&.context
        @subqueries = {}
        @constant_subqueries = {}
        @outer_bindings = []
        @group_correlations = []
        @cases = {}
        @math = {}
      end

      def validate(node, aggregates: false, inside_aggregate: false)
        return if node.nil?

        case node
        when ColumnRef
          binding = scope.resolve(node)
          @outer_bindings << binding unless scope.local?(binding) || @outer_bindings.include?(binding)
        when Literal, TypedLiteral, DecimalLiteral, Parameter, BoundColumn, CurrentDateTime
          nil
        when CaseExpression
          expression, _type = prepared_case(node)
          expressions = expression.is_a?(CaseExpression) ? case_children(expression) : [expression]
          expressions.each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
        when Subquery, Exists, InQuery, ArrayQuery
          validate(node.expression, aggregates: aggregates, inside_aggregate: inside_aggregate) if node.is_a?(InQuery)
          plan = subquery_plan(node)
          raise Error.new(90052, "Array query must have one column") if node.is_a?(ArrayQuery) && plan.columns.length != 1
          Type.check_comparable(type_of(node.expression), query_type(plan)) if node.is_a?(InQuery)
          plan.outer_bindings.each do |binding|
            @outer_bindings << binding unless scope.local?(binding) || @outer_bindings.include?(binding)
          end
        when WhenPredicate
          validate(node.predicate, aggregates: aggregates, inside_aggregate: inside_aggregate)
        when JsonConstructor, JsonFormat, JsonPredicate, TypePredicate
          children(node).each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
          evaluate(node) if constant?(node)
        when Function, Aggregate
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
          if node.is_a?(Aggregate)
            node.arguments.each { evaluate(it) if !it.is_a?(Star) && constant?(it) }
            node.order.each { validate(it.expression, inside_aggregate: true) }
            validate(node.filter, inside_aggregate: true)
            boolean(evaluate(node.filter)) if node.filter && constant?(node.filter)
            aggregate_order(node)
          end
          argument_type = type_of(node.arguments.first)
          if %w[SUM AVG].include?(node.name) && (argument_type.is_a?(ArrayType) || (%w[BINARY VARBINARY UUID JSON] + Temporal::NAMES).include?(argument_type&.name))
            raise Error.new(90015, "Invalid type for #{node.name}")
          end
          function_type(node) if datetime_function?(node)
          function_type(node) if ArrayFunctions::ARITIES.key?(node.name)
          function_type(node) if MathFunctions::ARITIES.key?(node.name)
          function_type(node) if node.name == "MOD"
        when Default, Star
          raise Error.new(42000, "Invalid expression #{node.class.name.split('::').last}")
        else
          children(node).each { validate(it, aggregates: aggregates, inside_aggregate: inside_aggregate) }
          if node.is_a?(IntervalDifference) || node.is_a?(TimeZoneExpression) || node.is_a?(ArrayElement) || node.is_a?(ArrayConstructor)
            type_of(node)
          elsif node.is_a?(Binary) && %w[= <> != < > <= >=].include?(node.operator)
            Type.check_comparable(type_of(node.left), type_of(node.right))
          elsif node.is_a?(Binary) && %w[+ - * / %].include?(node.operator)
            type = type_of(node)
            if type.is_a?(ArrayType)
              code = children(node).all? { constant?(it) } ? 50100 : 50000
              raise Error.new(code, "Arithmetic on arrays is unavailable")
            elsif %w[BINARY VARBINARY UUID JSON].include?(type.name)
              raise Error.new(50100, "Arithmetic on #{type.name}")
            end
          elsif node.is_a?(Predicate) && [:in, :between, :distinct, :not_distinct].include?(node.operator)
            node.arguments.drop(1).each { Type.check_comparable(type_of(node.arguments.first), type_of(it)) }
          end
        end
      end

      def contains_aggregate?(node)
        return false unless node
        return true if node.is_a?(Aggregate) || (node.is_a?(Function) && AGGREGATES.include?(node.name))

        children(node).any? { contains_aggregate?(it) }
      end

      def contains_subquery?(node)
        return true if node.is_a?(Subquery) || node.is_a?(Exists) || node.is_a?(InQuery) || node.is_a?(ArrayQuery)

        children(node).any? { contains_subquery?(it) }
      end

      def session_dependent?(node)
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
          expression = prepared_math(node).first
          return session_dependent?(expression) unless expression == node
        end
        return true if node.is_a?(CurrentDateTime)
        if node.is_a?(TimeZoneExpression)
          return true if node.zone.nil? || !type_of(node.expression).name.end_with?("WITH TIME ZONE")
        end
        if node.is_a?(Function) && %w[EXTRACT DATEDIFF].include?(node.name) && node.arguments.first.value.start_with?("TIMEZONE_")
          return true if node.arguments.drop(1).any? { !type_of(it).name.end_with?("WITH TIME ZONE") }
        end
        if node.is_a?(Cast) && %w[TIME TIMESTAMP].include?(node.type.name) && node.expression.is_a?(Literal) &&
            node.expression.value.is_a?(String) && node.expression.value.match?(/\d(?:Z|[+-]\d| [A-Za-z])/)
          return true
        end
        if node.is_a?(Cast) && session_date_conversion?(node.type, type_of(node.expression))
          return true
        end
        if node.is_a?(Function) && %w[COALESCE IFNULL].include?(node.name)
          return true if node.arguments.any? { session_date_conversion?(function_type(node), type_of(it)) }
        elsif node.is_a?(CaseExpression)
          if node.operand && node.branches.any? { |condition, _value| !condition.is_a?(WhenPredicate) && session_date_comparison?([node.operand, condition]) }
            return true
          end
          expression, type = prepared_case(node)
          values = expression.is_a?(CaseExpression) ? expression.branches.map(&:last) + [expression.fallback] : [expression]
          return true if values.any? { session_date_conversion?(type, type_of(it)) }
        elsif node.is_a?(Binary) && %w[= <> != < > <= >=].include?(node.operator)
          return true if session_date_comparison?([node.left, node.right])
        elsif node.is_a?(Predicate) && [:in, :between, :distinct, :not_distinct].include?(node.operator)
          return true if session_date_comparison?(node.arguments)
        elsif node.is_a?(Function) && node.name == "NULLIF"
          return true if session_date_comparison?(node.arguments)
        elsif node.is_a?(QuantifiedArray)
          return true if quantified_session_dependent?(node)
        end
        if node.is_a?(IntervalDifference) && IntervalUnits.year_month?(IntervalUnits.ordinal(Intervals.qualifier(node.type)))
          names = [type_of(node.left).name, type_of(node.right).name]
          return true if names.any? { Temporal.time_type?(it) } && !names.all? { Temporal.time_type?(it) }
        end
        children(node).any? { session_dependent?(it) }
      end

      def validate_grouping(node, groups)
        return unless node
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
          expression = prepared_math(node).first
          return validate_grouping(expression, groups) unless expression == node
        end
        return if groups.any? { canonical(it) == canonical(node) }
        return if node.is_a?(Aggregate) || (node.is_a?(Function) && AGGREGATES.include?(node.name))
        if node.is_a?(Subquery) || node.is_a?(Exists) || node.is_a?(InQuery) || node.is_a?(ArrayQuery)
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
        when TypedLiteral then node.value
        when DecimalLiteral then node.value
        when CurrentDateTime
          raise Error.new(50100, "Current-clock function requires a SQL session context") unless context

          type_of(node).convert(context.current_timestamp, context: context)
        when TimeZoneExpression
          TimeZoneOperations.evaluate(evaluate(node.expression, row, group), type_of(node),
            node.zone && evaluate(node.zone, row, group), context: context, local: node.zone.nil?)
        when Parameter
          value = @parameters.fetch(node.index)
          value.equal?(UNBOUND_PARAMETER) ? nil : value
        when ColumnRef then row.fetch(scope.resolve(node).key)
        when BoundColumn then row.fetch(node.binding.key)
        when Unary
          value = evaluate(node.operand, row, group)
          return nil if value.nil?

          case node.operator
          when "NOT" then !boolean(value)
          when "+" then value.is_a?(IntervalValue) || value.is_a?(DecfloatValue) ? value : numeric(value)
          when "-"
            return type_of(node).convert(-value) if value.is_a?(Float)

            value.is_a?(IntervalValue) || value.is_a?(DecfloatValue) ? value.negate : check_integer(-numeric(value), node)
          end
        when Binary then binary(node, row, group)
        when IntervalDifference
          left, right = [node.left, node.right].map { evaluate(it, row, group) }
          left.nil? || right.nil? ? nil : IntervalOperations.forced_difference(node.type, left, right, context: context)
        when Predicate then predicate(node, row, group)
        when Cast
          value = evaluate(node.expression, row, group)
          if node.type.name == "DECFLOAT" && value.is_a?(BigDecimal) && (text = json_number_text(node.expression))
            value = DecfloatValue.parse(text)
          end
          value = json_value(node.expression, value) if node.type.name == "JSON" && !value.nil?
          node.type.convert(value, cast: true, source_type: type_of(node.expression), context: context)
        when JsonFormat
          value = evaluate(node.expression, row, group)
          if value.is_a?(String) || value.nil?
            JsonFunctions.format(value, type_of(node.expression))
          else
            json_value(node.expression, value)
          end
        when JsonPredicate then JsonFunctions.predicate(node, evaluate(node.expression, row, group))
        when TypePredicate then JsonFunctions.type_predicate(node, evaluate(node.expression, row, group), type_of(node.expression))
        when JsonConstructor then json_constructor(node, row, group)
        when Aggregate then aggregate(node, group)
        when Function then function(node, row, group)
        when RowConstructor then RowValue.new(node.expressions.map { evaluate(it, row, group) })
        when ArrayConstructor
          type_of(node).convert(ArrayValue.new(node.expressions.map { evaluate(it, row, group) }, type_of(node).element_type), cast: true, context: context)
        when ArrayElement
          array, index = [node.array, node.index].map { evaluate(it, row, group) }
          return nil if array.nil? || index.nil?

          index = Type.new("INTEGER", nil, nil).convert(index)
          return array.element(index) if array.is_a?(JsonValue)
          raise Error.new(22034, "Array index #{index} is outside 1..#{array.values.length}") unless (1..array.values.length).cover?(index)

          array.values[index - 1]
        when ArrayQuery
          plan = subquery_plan(node)
          ArrayType.new(plan.types.first, ArrayValue::MAX_CARDINALITY).convert(ArrayValue.new(plan.execute(row).rows.map(&:first), plan.types.first), cast: true, context: context)
        when Subquery
          plan = subquery_plan(node)
          plan.constant? ? constant_subquery(node, plan) : scalar_value(plan, row)
        when Exists then !subquery_plan(node).execute(row, max_rows: 1).rows.empty?
        when InQuery then quantified_query(node, row, group)
        when QuantifiedArray then quantified_array(node, row, group)
        when CaseExpression
          expression, type = prepared_case(node)
          return type.convert(evaluate(expression, row, group), cast: true, context: context) unless expression.is_a?(CaseExpression)

          operand = evaluate(expression.operand, row, group) if expression.operand
          branch = expression.branches.find do |condition, _value|
            expression.operand ? case_match?(operand, condition, row, group) : boolean(evaluate(condition, row, group)) == true
          end
          value = evaluate(branch ? branch.last : expression.fallback, row, group)
          type.convert(value, cast: true, context: context)
        else raise Error.new(42000, "Invalid expression")
        end
      end

      def boolean(value)
        Type.new("BOOLEAN", nil, nil).convert(value)
      end

      def case_match?(operand, condition, row = {}, group = nil)
        return equals(operand, evaluate(condition, row, group)) == true unless condition.is_a?(WhenPredicate)

        node = condition.predicate
        result = case node
        when InQuery then quantified_query(node, row, group, operand)
        when QuantifiedArray then quantified_array(node, row, group, operand)
        when Binary then evaluate(node.with(left: TypedLiteral.new(operand, type_of(node.left), false)), row, group)
        when Predicate
          evaluate(node.with(arguments: [TypedLiteral.new(operand, type_of(node.arguments.first), false), *node.arguments.drop(1)]), row, group)
        when JsonPredicate, TypePredicate
          evaluate(node.with(expression: TypedLiteral.new(operand, type_of(node.expression), false)), row, group)
        end
        result == true
      end

      def compare(left, right, untyped: false)
        return 0 if left.nil? && right.nil?
        return -1 if left.nil?
        return 1 if right.nil?
        if left.is_a?(RowValue) || right.is_a?(RowValue)
          left, right = row_pair(left, right)
          left.values.zip(right.values).each do |a, b|
            comparison = compare(a, b, untyped: untyped)
            return comparison unless comparison.zero?
          end
          return 0
        end
        if left.is_a?(ArrayValue) || right.is_a?(ArrayValue)
          left = ArrayValue.new([left], type_of(Literal.new(left))) unless left.is_a?(ArrayValue)
          right = ArrayValue.new([right], type_of(Literal.new(right))) unless right.is_a?(ArrayValue)
          array_pairs(left, right).each do |a, b|
            comparison = compare(a, b, untyped: untyped)
            return comparison unless comparison.zero?
          end
          return left.values.length <=> right.values.length
        end
        if untyped
          type = Type.common([type_of(Literal.new(left)), type_of(Literal.new(right))])
          left, right = [left, right].map { type.coerce(it, context: context) }
          return compare(left, right)
        end
        if left.is_a?(JsonValue) || right.is_a?(JsonValue)
          return JsonValue.convert(left).bytes <=> JsonValue.convert(right).bytes
        end
        return DecfloatValue.convert(left) <=> DecfloatValue.convert(right) if left.is_a?(DecfloatValue) || right.is_a?(DecfloatValue)
        if left.is_a?(IntervalValue) || right.is_a?(IntervalValue)
          type = Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          return Intervals.convert(left, Intervals.qualifier(type)).absolute <=> Intervals.convert(right, Intervals.qualifier(type)).absolute
        elsif Temporal.value?(left) || Temporal.value?(right)
          Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          return Temporal.compare(left, right, context: context)
        elsif left.is_a?(UUIDValue) || right.is_a?(UUIDValue)
          Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          uuid = Type.new("UUID", nil, nil)
          return uuid.convert(left) <=> uuid.convert(right)
        elsif BinaryString.binary?(left) || BinaryString.binary?(right)
          Type.check_comparable(type_of(Literal.new(left)), type_of(Literal.new(right)))
          return left.b <=> right.b
        elsif left.is_a?(String) && right.is_a?(String)
          return CharacterString.sort_key(left) <=> CharacterString.sort_key(right)
        end
        if left.is_a?(Numeric) || right.is_a?(Numeric)
          left = numeric(left)
          right = numeric(right)
        elsif [true, false].include?(left) || [true, false].include?(right)
          left = boolean(left) ? 1 : 0
          right = boolean(right) ? 1 : 0
        end
        result = FloatingOperations.compare(left, right)
        raise Error.new(22018, "Cannot compare #{left.inspect} and #{right.inspect}") if result.nil?

        result
      end

      def equals(left, right, null_safe: false)
        return null_safe ? left.nil? && right.nil? : nil if left.nil? || right.nil?
        if null_safe && [left, right].any? { it.is_a?(ArrayValue) || it.is_a?(RowValue) }
          return compare(left, right, untyped: true).zero?
        end
        if left.is_a?(RowValue) || right.is_a?(RowValue) || left.is_a?(ArrayValue) || right.is_a?(ArrayValue)
          if (left.is_a?(ArrayValue) || right.is_a?(ArrayValue)) && !left.is_a?(RowValue) && !right.is_a?(RowValue)
            left = ArrayValue.new([left], type_of(Literal.new(left))) unless left.is_a?(ArrayValue)
            right = ArrayValue.new([right], type_of(Literal.new(right))) unless right.is_a?(ArrayValue)
            return false if left.values.length != right.values.length
            unknown = false
            array_pairs(left, right).each do |a, b|
              result = equals(a, b, null_safe: null_safe)
              return false if result == false

              unknown = true if result.nil?
            end
            return unknown ? nil : true
          else
            left, right = row_pair(left, right)
          end
          results = left.values.zip(right.values).map { |a, b| equals(a, b, null_safe: null_safe) }
          return false if results.include?(false)
          return nil if results.include?(nil)

          return true
        end
        compare(left, right).zero?
      end

      def type_of(node)
        case node
        when TypedLiteral then node.type
        when DecimalLiteral then Type.new("NUMERIC", node.precision, node.scale)
        when CurrentDateTime
          name = {"CURRENT_DATE" => "DATE", "LOCALTIME" => "TIME", "LOCALTIMESTAMP" => "TIMESTAMP",
            "CURRENT_TIME" => "TIME WITH TIME ZONE", "CURRENT_TIMESTAMP" => "TIMESTAMP WITH TIME ZONE"}.fetch(node.name)
          Temporal.type(name, node.scale)
        when TimeZoneExpression then TimeZoneOperations.type(type_of(node.expression))
        when ColumnRef then scope.resolve(node).type
        when BoundColumn then node.binding.type
        when Cast then node.type
        when IntervalDifference
          unless [node.left, node.right].all? { Temporal::NAMES.include?(type_of(it).name) }
            raise Error.new(42001, "An interval-qualified difference requires datetime operands")
          end
          IntervalOperations.type("-", type_of(node.left), type_of(node.right))
        when RowConstructor then RowType.new(node.expressions.map { type_of(it) })
        when ArrayConstructor
          types = node.expressions.map { type_of(it) }
          if types.any? { it.name == "UNKNOWN" } && types.all? { %w[NULL UNKNOWN].include?(it.name) }
            raise Error.new(50004, "Array component type is unknown")
          end
          ArrayType.new(ArrayType.element_common(types), node.expressions.length)
        when ArrayElement
          type = type_of(node.array)
          return Type.new("JSON", JsonValue::MAX_PRECISION, 0) if type.name == "JSON"
          return type if type.name == "NULL"
          raise Error.new(50004, "Array input type is unknown") if type.name == "UNKNOWN"
          raise Error.new(90008, "Array access requires an array") unless type.is_a?(ArrayType)

          type.element_type
        when ArrayQuery
          plan = subquery_plan(node)
          raise Error.new(90052, "Array query must have one column") unless plan.columns.length == 1

          ArrayType.new(plan.types.first, ArrayValue::MAX_CARDINALITY)
        when Subquery
          plan = subquery_plan(node)
          plan.constant? && constant_subquery(node, plan).nil? ? Type.new("NULL", nil, nil) : query_type(plan)
        when Exists, InQuery, QuantifiedArray, WhenPredicate, JsonPredicate, TypePredicate then Type.new("BOOLEAN", nil, nil)
        when JsonFormat
          constant?(node.expression) && evaluate(node.expression).nil? ? Type.new("NULL", nil, nil) : Type.new("JSON", JsonValue::MAX_PRECISION, 0)
        when JsonConstructor then Type.new("JSON", JsonValue::MAX_PRECISION, 0)
        when CaseExpression then prepared_case(node).last
        when Parameter
          value = @parameters.fetch(node.index)
          value.equal?(UNBOUND_PARAMETER) ? Type.new("UNKNOWN", nil, nil) : type_of(Literal.new(value))
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
          when String
            binary = BinaryString.binary?(node.value)
            Type.new(binary ? "VARBINARY" : "VARCHAR", binary ? node.value.bytesize : CharacterString.sort_key(node.value).bytesize / 2, nil)
          when UUIDValue then Type.new("UUID", nil, nil)
          when JsonValue then Type.new("JSON", JsonValue::MAX_PRECISION, 0)
          when DecfloatValue then Type.new("DECFLOAT", node.value.precision, 0)
          when DateValue then Temporal.type("DATE")
          when TimeValue then Temporal.type("TIME", 9)
          when TimestampValue then Temporal.type("TIMESTAMP", 9)
          when TimeTimeZoneValue, TimestampTimeZoneValue then Temporal.type(Temporal.name(node.value), 9)
          when IntervalValue then Intervals.type(node.value.qualifier, 18, 9)
          when true, false then Type.new("BOOLEAN", nil, nil)
          when nil then Type.new("NULL", nil, nil)
          when RowValue then RowType.new(node.value.values.map { type_of(Literal.new(it)) })
          when ArrayValue then ArrayType.new(node.value.element_type, node.value.values.length)
          end
        when Unary then node.operator == "NOT" ? Type.new("BOOLEAN", nil, nil) : type_of(node.operand)
        when Predicate then Type.new("BOOLEAN", nil, nil)
        when Function, Aggregate then function_type(node)
        when Binary
          return Type.new("BOOLEAN", nil, nil) if %w[AND OR = <> != < > <= >=].include?(node.operator)
          if node.operator == "||"
            types = [type_of(node.left), type_of(node.right)]
            if types.any? { it.is_a?(ArrayType) }
              types = types.map { it.is_a?(ArrayType) ? it : ArrayType.new(it, 1) }
              type = Type.common(types)
              return type.with(precision: ArrayValue::MAX_CARDINALITY)
            end
            names = types.map(&:name)
            return Type.new((names - %w[BINARY VARBINARY NULL]).empty? && (names & %w[BINARY VARBINARY]).any? ? "VARBINARY" : "VARCHAR", nil, nil)
          end

          types = [type_of(node.left), type_of(node.right)]
          return Type.common(types) if types.any? { it.is_a?(ArrayType) }
          return IntervalOperations.type(node.operator, *types) if IntervalOperations.applicable?(node.operator, *types)
          return TemporalOperations.type(node.operator, *types) if types.any? { Temporal::NAMES.include?(it&.name) }

          type = Type.common(types)
          return FloatingOperations.type(type) if FloatingOperations::NAMES.include?(type.name)
          if node.operator == "%" && type.name == "DECFLOAT"
            return types.last if (%w[NUMERIC REAL DOUBLE DECFLOAT] + Type::INTEGER_LIMITS.keys).include?(types.last.name)
            return type
          end
          return NumericOperations.type(node.operator, *types) if %w[NUMERIC DECFLOAT].include?(type.name)
          type
        end
      end

      def children(node)
        case node
        when Unary then [node.operand]
        when Binary, IntervalDifference then [node.left, node.right]
        when Predicate, Function then node.arguments
        when Aggregate then [*node.arguments, *node.order.map(&:expression), node.filter].compact
        when Cast then [node.expression]
        when TimeZoneExpression then [node.expression, node.zone].compact
        when RowConstructor, ArrayConstructor then node.expressions
        when ArrayElement then [node.array, node.index]
        when QuantifiedArray then [node.expression, node.array]
        when WhenPredicate then [node.predicate]
        when JsonFormat, JsonPredicate, TypePredicate then [node.expression]
        when JsonConstructor then node.arguments
        when CaseExpression
          expression = prepared_case(node).first
          expression.is_a?(CaseExpression) ? case_children(expression) : [expression]
        else []
        end
      end

      def constant_expression?(node)
        constant?(node)
      end

      def optimized_expression(node)
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
          expression, type = prepared_math(node)
          return optimized_expression(expression) unless expression == node
          return MathFunctions.literal(evaluate(node), type) if constant?(node)
        end
        if [JsonFormat, JsonPredicate, TypePredicate, JsonConstructor].any? { node.is_a?(it) } && constant?(node)
          value = evaluate(node)
          return TypedLiteral.new(value, type_of(node), value.nil? && !node.is_a?(JsonFormat))
        end
        if node.is_a?(QuantifiedArray) && constant?(node)
          value = evaluate(node)
          return TypedLiteral.new(value, Type.new("BOOLEAN", nil, nil), value.nil?)
        end
        if node.is_a?(Aggregate)
          return node.with(arguments: node.arguments.map { optimized_expression(it) }, order: aggregate_order(node))
        end
        if node.is_a?(CaseExpression)
          expression, type = prepared_case(node)
          unless expression.is_a?(CaseExpression)
            return TypedLiteral.new(nil, type, true) if expression.is_a?(Literal) && expression.value.nil? && type.name != "NULL"

            return optimized_expression(expression)
          end
        end
        if node.is_a?(InQuery) && node.query.is_a?(Select)
          return node.with(query: subquery_plan(node).expanded_statement)
        end
        if node.is_a?(Binary) && %w[+ - * /].include?(node.operator) && constant?(node)
          type = type_of(node)
          if %w[NUMERIC DECFLOAT REAL DOUBLE].include?(type.name) || Type::INTEGER_LIMITS.key?(type.name)
            return NumericOperations.literal(evaluate(node), type)
          end
        end
        if (node.is_a?(ArrayConstructor) || node.is_a?(ArrayElement)) && constant?(node)
          value = evaluate(node)
          return value.nil? ? TypedLiteral.new(value, type_of(node), type_of(node).name != "NULL") : Literal.new(value)
        end
        if node.is_a?(TimeZoneExpression) && constant?(node)
          value = evaluate(node)
          return value.nil? ? node : Literal.new(value)
        end
        if node.is_a?(Cast) && Intervals.name?(node.type.name) && constant?(node.expression)
          return node.with(expression: Literal.new(evaluate(node)))
        end
        node = dateadd_expression(node) if node.is_a?(Binary)
        if node.is_a?(Subquery) && (plan = subquery_plan(node)).constant?
          Literal.new(constant_subquery(node, plan))
        elsif datetime_function?(node) && constant?(node)
          type = function_type(node)
          value = evaluate(node)
          value = value.to_i if value.is_a?(BigDecimal) && type.scale == 0 && value.frac.zero?
          literal = Literal.new(value)
          value.nil? && type.name != "NULL" ? Cast.new(literal, type) : literal
        elsif datetime_function?(node)
          node.with(arguments: node.arguments.map { optimized_expression(it) })
        else
          node
        end
      end

      private

      public def prepared_math(node)
        @math[node] ||= begin
          call = node
          argument_type = type_of(call.arguments.first)
          if call.name == "TRUNC" && argument_type.name == "VARCHAR" && constant?(call.arguments.first)
            target = Temporal.type("TIMESTAMP", 0)
            value = evaluate(Cast.new(call.arguments.first, target))
            call = call.with(arguments: [TypedLiteral.new(value, target, true), *call.arguments.drop(1)])
            argument_type = target
          end
          temporal = call.name == "TRUNC" && MathFunctions::TEMPORAL_TRUNC.include?(argument_type.name)
          scale_argument = call.arguments[1] unless temporal || %w[FLOOR CEIL ROUNDMAGIC].include?(call.name)
          known_scale = scale_argument.nil? || constant?(scale_argument)
          scale_value = scale_argument ? (evaluate(scale_argument) if known_scale) : 0
          scale_value = MathFunctions.scale(scale_value) if known_scale && !scale_value.nil? && !temporal && call.name != "ROUNDMAGIC"
          expression, type = MathFunctions.plan(call, argument_type, known_scale: known_scale, scale_value: scale_value)
          if expression != call && constant?(expression)
            if Type::INTEGER_LIMITS.key?(type&.name)
              expression = MathFunctions.literal(evaluate(expression), type)
            elsif type&.name == "NUMERIC"
              value = evaluate(expression)
              literal = MathFunctions.literal(value, type)
              actual = type_of(literal)
              expression = [type.precision,type.scale] == [actual.precision,actual.scale] && !type.declared_name ? literal : TypedLiteral.new(value,type,true)
            elsif expression.is_a?(Cast) && expression.type.name == "TIMESTAMP"
              expression = TypedLiteral.new(evaluate(expression), expression.type, true)
            end
          end
          [expression, type || type_of(expression)]
        end
      end

      private

      def json_value(expression, value)
        JsonValue.convert(value, source_type: type_of(expression), number_text: json_number_text(expression))
      end

      def json_number_text(expression)
        number = expression.is_a?(DecimalLiteral) ? expression.text : nil
        if expression.is_a?(Unary) && expression.operand.is_a?(DecimalLiteral)
          text = expression.operand.text
          number = text && (expression.operator == "-" ? "-#{text}" : text)
        end
        number
      end

      def json_constructor(node, row, group)
        arguments = node.arguments
        single = arguments.first if node.kind == :array && arguments.length == 1
        query = single.is_a?(JsonFormat) ? single.expression : single
        if query.is_a?(Subquery)
          plan = subquery_plan(query)
          values = if plan.constant?
            [constant_subquery(query, plan)]
          else
            plan.execute(row).rows.map { it.length == 1 ? it.first : RowValue.new(it) }
          end
          values = values.map { JsonFunctions.format(it, query_type(plan)) } if single.is_a?(JsonFormat)
          type = single.is_a?(JsonFormat) ? Type.new("JSON", JsonValue::MAX_PRECISION, 0) : query_type(plan)
          entries = values.map { JsonValue.convert(it, source_type: type) }
        else
          entries = []
          if node.kind == :object
            arguments.each_slice(2) do |key, argument|
              name = evaluate(key, row, group)
              raise Error.new(90008, "NULL JSON_OBJECT key") if name.nil?

              key_type = type_of(key)
              text = if name.is_a?(BigDecimal)
                lexical = json_number_text(key)
                lexical && lexical.match?(/[eE]/) ? DecfloatValue.parse(lexical).to_s : ArrayType.decimal_text(name, key_type.scale)
              elsif name.is_a?(Float)
                JsonValue.float_text(name, real: key_type.name == "REAL")
              else
                Type.new("VARCHAR", nil, nil).convert(name, source_type: key_type, context: context)
              end
              entries << text << json_value(argument, evaluate(argument, row, group))
            end
          else
            entries = arguments.map { json_value(it, evaluate(it, row, group)) }
          end
        end
        JsonFunctions.construct(node, entries)
      end

      def quantified_array(node, row, group, value = evaluate(node.expression, row, group))
        array = evaluate(node.array, row, group)
        return nil if array.nil?

        values = array.is_a?(ArrayValue) ? array.values : [array]
        right_type = array.is_a?(ArrayValue) ? array.element_type : type_of(node.array)
        QuantifiedComparisons.evaluate(value, values, node.operator, node.all, self, type_of(node.expression), right_type)
      end

      def quantified_query(node, row, group, value = evaluate(node.expression, row, group))
        plan = subquery_plan(node)
        rows = plan.distinct_if_possible(row)
        result = if node.operator == "=" && !node.all
          query_membership(value, rows, plan, type_of(node.expression))
        else
          values = rows.map { value.is_a?(RowValue) || it.length != 1 ? RowValue.new(it) : it.first }
          QuantifiedComparisons.evaluate(value, values, node.operator, node.all, self, type_of(node.expression), query_type(plan))
        end
        result.nil? ? nil : (node.negated ? !result : result)
      end

      def query_membership(value, rows, plan, left_type)
        return false if rows.empty?
        return nil if contains_null?(value)
        return nil if plan.types.length == 1 && plan.types.first.name == "NULL"

        if plan.columns.length == 1 && value.is_a?(RowValue)
          value = value.values.first
          left_type = left_type.fields.first if left_type.is_a?(RowType)
        end
        values = rows.map { it.length == 1 ? it.first : RowValue.new(it) }
        return true if values.any? { QuantifiedComparisons.compare(value, it, "IS NOT DISTINCT FROM", self, left_type, query_type(plan)) }

        values.any? { contains_null?(it) } ? nil : false
      end

      def session_date_conversion?(target, source)
        return false unless target && source
        if target.is_a?(RowType)
          fields = source.is_a?(RowType) ? source.fields : [source]
          return target.fields.zip(fields).any? { session_date_conversion?(*it) }
        end
        if target.is_a?(ArrayType)
          return session_date_conversion?(target.element_type, source.is_a?(ArrayType) ? source.element_type : source)
        end
        return false unless Temporal::NAMES.include?(target.name)
        return true if target.name != "DATE" && %w[CHAR VARCHAR].include?(source.name)
        case target.name
        when "DATE" then source.name == "TIMESTAMP WITH TIME ZONE"
        when "TIME" then ["TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"].include?(source.name)
        when "TIMESTAMP" then ["TIME", "TIME WITH TIME ZONE", "TIMESTAMP WITH TIME ZONE"].include?(source.name)
        when "TIME WITH TIME ZONE" then %w[TIME TIMESTAMP].include?(source.name)
        when "TIMESTAMP WITH TIME ZONE" then (Temporal::NAMES - [target.name]).include?(source.name)
        else false
        end
      end

      def session_date_comparison?(nodes)
        first, *others = nodes.map { type_of(it) }
        others.any? do |other|
          types = [first, other]
          target = Type.check_comparable(*types)
          types.any? { session_date_conversion?(target, it) }
        end
      end

      def quantified_session_dependent?(node)
        left, right = type_of(node.expression), type_of(node.array)
        right = right.element_type if right.is_a?(ArrayType)
        target = Type.common([left, right])
        [left, right].any? { session_date_conversion?(target, it) }
      rescue Error
        false
      end

      def datetime_function?(node)
        node.is_a?(Function) && (DateTimeFunctions::NAMES.include?(node.name) || CalendarFunctions::NAMES.include?(node.name))
      end

      def dateadd_expression(node)
        return node unless %w[+ -].include?(node.operator)

        left, right = type_of(node.left), type_of(node.right)
        if %w[DATE TIMESTAMP].include?(left.name) && right.name == "INTEGER"
          temporal, count = node.left, node.right
          if node.operator == "-"
            count = constant?(count) ? Literal.new(-evaluate(count)) : Unary.new("-", count)
          end
        elsif node.operator == "+" && left.name == "INTEGER" && %w[DATE TIMESTAMP].include?(right.name)
          temporal, count = node.right, node.left
        else
          return node
        end
        Function.new("DATEADD", [Literal.new("DAY"), count, temporal], false)
      end

      def scalar_value(plan, row)
        result = plan.execute(row, max_rows: 2)
        raise Error.new(90053, "Scalar subquery contains more than one row") if result.rows.length > 1

        values = result.rows.first || Array.new(plan.columns.length)
        values.length == 1 ? values.first : RowValue.new(values)
      end

      def constant_subquery(node, plan)
        @constant_subqueries.fetch(node) { @constant_subqueries[node] = scalar_value(plan, {}) }
      end

      def case_children(node)
        [node.operand, *node.branches.flatten, node.fallback].compact
      end

      public def prepared_case(node)
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
        return false if session_dependent?(node)

        case node
        when Literal, TypedLiteral, DecimalLiteral then true
        when TimeZoneExpression then !node.zone.nil? && children(node).all? { constant?(it) }
        when Subquery then subquery_plan(node).constant?
        when Unary, Binary, IntervalDifference, Predicate, Cast, RowConstructor, ArrayConstructor, ArrayElement, QuantifiedArray,
          JsonFormat, JsonPredicate, TypePredicate, JsonConstructor then children(node).all? { constant?(it) }
        when Function then FUNCTIONS.key?(node.name) && !AGGREGATES.include?(node.name) && children(node).all? { constant?(it) }
        when CaseExpression
          expression = prepared_case(node).first
          !expression.is_a?(CaseExpression) && constant?(expression)
        else false
        end
      end

      public def contains_null?(value)
        value.nil? || ([RowValue, ArrayValue].any? { value.is_a?(it) } && value.values.any? { contains_null?(it) })
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
        if left.is_a?(ArrayValue) && right.is_a?(ArrayValue)
          array_pairs(left, right).each do |a, b|
            result = nullable_compare(a, b)
            return result if result.nil? || !result.zero?
          end
          return left.values.length <=> right.values.length
        end
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

      def in_values(value, candidates, types)
        unknown = false
        candidates.each_with_index do |candidate, index|
          left, right = comparison_pair(value, candidate, types.first, types[index + 1])
          result = equals(left, right)
          return true if result == true

          unknown = true if result.nil?
        end
        unknown ? nil : false
      end

      def canonical(node)
        if node.is_a?(Function) && MathFunctions::ARITIES.key?(node.name)
          expression = prepared_math(node).first
          return canonical(expression) unless expression == node
        end
        case node
        when ColumnRef then BoundColumn.new(scope.resolve(node))
        when Unary then node.with(operand: canonical(node.operand))
        when Binary, IntervalDifference then node.with(left: canonical(node.left), right: canonical(node.right))
        when Predicate, Function then node.with(arguments: node.arguments.map { canonical(it) })
        when Aggregate
          node.with(arguments: node.arguments.map { canonical(it) },
            order: node.order.map { it.with(expression: canonical(it.expression)) }, filter: node.filter && canonical(node.filter))
        when Cast then node.with(expression: canonical(node.expression))
        when TimeZoneExpression then node.with(expression: canonical(node.expression), zone: node.zone && canonical(node.zone))
        when RowConstructor, ArrayConstructor then node.with(expressions: node.expressions.map { canonical(it) })
        when ArrayElement then node.with(array: canonical(node.array), index: canonical(node.index))
        when QuantifiedArray then node.with(expression: canonical(node.expression), array: canonical(node.array))
        when WhenPredicate then node.with(predicate: canonical(node.predicate))
        when JsonFormat, JsonPredicate, TypePredicate then node.with(expression: canonical(node.expression))
        when JsonConstructor then node.with(arguments: node.arguments.map { canonical(it) })
        when CaseExpression
          node.with(operand: node.operand && canonical(node.operand),
            branches: node.branches.map { |condition, value| [canonical(condition), canonical(value)] }, fallback: canonical(node.fallback))
        else node
        end
      end

      def function_type(node)
        if MathFunctions::ARITIES.key?(node.name)
          expression, type = prepared_math(node)
          return type unless expression == node && constant?(node)

          return type_of(MathFunctions.literal(evaluate(node), type))
        end
        if ArrayFunctions::ARITIES.key?(node.name)
          type = ArrayFunctions.type(node.name, type_of(node.arguments.first))
          if constant?(node) && (value = evaluate(node))
            return type_of(Literal.new(value))
          end
          return type
        end
        if CalendarFunctions::NAMES.include?(node.name)
          field = node.name == "LAST_DAY" ? nil : node.arguments.first.value
          type = CalendarFunctions.type(node.name, field, type_of(node.arguments.last))
          return constant?(node) ? CalendarFunctions.constant_type(node.name, field, evaluate(node), type) : type
        end
        if DateTimeFunctions::NAMES.include?(node.name)
          type = DateTimeFunctions.type(node.name, node.arguments.first.value, type_of(node.arguments.last))
          if constant?(node)
            value = evaluate(node)
            return type_of(Literal.new(value)) if node.name == "DATEADD" && !value.nil?
          end
          return type
        end
        argument_type = type_of(node.arguments.first)
        if %w[SUM AVG].include?(node.name) && argument_type && Intervals.name?(argument_type.name)
          return IntervalOperations.aggregate_type(node.name, argument_type)
        end
        if %w[SUM AVG].include?(node.name) && %w[DOUBLE DECFLOAT].include?(argument_type&.name)
          return Type.new("DECFLOAT", [Type.decfloat_precision(argument_type) + 10, 100_000].min, 0)
        end
        case node.name
        when "ARRAY_AGG" then ArrayType.new(argument_type, ArrayValue::MAX_CARDINALITY)
        when "COUNT", "LENGTH", "CHAR_LENGTH", "OCTET_LENGTH", "BIT_LENGTH" then Type.new("BIGINT", nil, 0)
        when "UPPER", "UCASE", "LOWER", "LCASE" then Type.new("VARCHAR", nil, nil)
        when "SIGN" then Type.new("INTEGER", nil, 0)
        when "ABS", "MIN", "MAX", "NULLIF" then argument_type
        when "COALESCE", "IFNULL" then Type.common(node.arguments.map { type_of(it) })
        when "MOD"
          NumericOperations.modulus_type(node.arguments.map { type_of(it) })
        when "SUM"
          return nil unless argument_type
          case argument_type.name
          when "TINYINT", "SMALLINT", "INTEGER" then Type.new("BIGINT", nil, 0)
          when "BIGINT" then Type.new("NUMERIC", 100_000, 0)
          when "REAL" then Type.new("DOUBLE", 53, nil)
          else argument_type
          end
        when "AVG"
          if argument_type && %w[BIGINT NUMERIC].include?(argument_type.name)
            Type.new("NUMERIC", 100_000, (argument_type.scale || 0) + 10)
          else
            Type.new("DOUBLE", 53, nil)
          end
        end
      end

      def numeric(value)
        if BinaryString.binary?(value) || value.is_a?(UUIDValue) || Temporal.value?(value)
          raise Error.new(50100, "Numeric operation on binary or UUID values")
        end
        return value if value.is_a?(Numeric)
        return value ? 1 : 0 if value == true || value == false

        BigDecimal(value.to_s)
      rescue ArgumentError
        raise Error.new(22018, "Cannot convert #{value.inspect} to number")
      end

      def comparison_pair(left, right, left_type, right_type)
        if [left_type, right_type].any? { it&.name == "CHAR" } &&
            [left, right].all? { it.is_a?(String) && !BinaryString.binary?(it) }
          return [left, right].map { CharacterString.trim_spaces(it) }
        end
        FloatingOperations.comparison_pair(left, right, [left_type, right_type])
      end

      def array_pairs(left, right)
        count = [left.values.length, right.values.length].min
        left.values.first(count).zip(right.values).map { |a, b| comparison_pair(a, b, left.element_type, right.element_type) }
      end

      def value_equals(left, right, left_type: nil, right_type: nil)
        left, right = comparison_pair(left, right, left_type, right_type)
        compare(left, right, untyped: true).zero?
      end

      def check_integer(value, node)
        type = type_of(node)
        return value unless value.is_a?(Integer) && type && Type::INTEGER_LIMITS.key?(type.name)

        type.convert(value)
      end

      def binary(node, row, group)
        left = evaluate(node.left, row, group)
        if %w[+ - * /].include?(node.operator)
          sources = [type_of(node.left), type_of(node.right)]
          result_type = type_of(node)
          if FloatingOperations::NAMES.include?(result_type.name)
            return FloatingOperations.evaluate(node.operator, result_type, sources,
              ->(index) { index.zero? ? left : evaluate(node.right, row, group) })
          end
        end
        if node.operator == "||" && (type = type_of(node)).is_a?(ArrayType)
          left = type.coerce(left, context: context)
          return nil if left.nil?

          right = type.coerce(evaluate(node.right, row, group), context: context)
          return nil if right.nil?

          return ArrayValue.new(left.values + right.values, type.element_type)
        end
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
        if %w[+ - * / %].include?(node.operator)
          left_type, right_type = type_of(node.left), type_of(node.right)
          if IntervalOperations.applicable?(node.operator, left_type, right_type)
            return IntervalOperations.evaluate(node.operator, left, right, left_type, right_type, context: context)
          end
          if [left_type, right_type].any? { Temporal::NAMES.include?(it&.name) }
            return TemporalOperations.evaluate(node.operator, left, right, left_type, right_type, context: context)
          end
          if Type.common([left_type, right_type]).name == "DECFLOAT"
            left = DecfloatValue.convert(left, source_type: left_type)
            right = DecfloatValue.convert(right, source_type: right_type)
            return case node.operator
            when "+" then left.add(right)
            when "-" then left.subtract(right)
            when "*" then left.multiply(right)
            when "/" then left.divide(right, type_of(node).precision)
            when "%" then type_of(node).coerce(left.remainder(right))
            end
          end
        end
        if %w[= <> != < > <= >=].include?(node.operator) && (left.is_a?(RowValue) ^ right.is_a?(RowValue))
          raise Error.new(22018, "Cannot compare row and scalar values")
        end
        if %w[= <> != < > <= >=].include?(node.operator)
          left, right = FloatingOperations.comparison_pair(left, right, [type_of(node.left), type_of(node.right)])
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
            if type_of(node).name == "NUMERIC"
              NumericOperations.divide(left, right, type_of(node).scale)
            elsif left.is_a?(Integer) && right.is_a?(Integer)
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
          left, right = comparison_pair(left, right, *node.arguments.first(2).map { type_of(it) })
          equal = equals(left, right, null_safe: true)
          node.operator == :not_distinct ? equal : !equal
        when :between
          types = node.arguments.map { type_of(it) }
          lower_comparison = nullable_compare(*comparison_pair(left, right, *types.first(2)))
          upper_comparison = nullable_compare(*comparison_pair(left, extra, types[0], types[2]))
          low = lower_comparison.nil? ? nil : lower_comparison >= 0
          high = upper_comparison.nil? ? nil : upper_comparison <= 0
          return false if low == false || high == false

          low.nil? || high.nil? ? nil : true
        when :in
          in_values(left, values.drop(1), node.arguments.map { type_of(it) })
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
        if MathFunctions::ARITIES.key?(node.name)
          expression, type = prepared_math(node)
          return evaluate(expression, row, group) unless expression == node

          value = evaluate(node.arguments.first, row, group)
          return nil if value.nil?

          scale = node.arguments.length > 1 ? evaluate(node.arguments[1], row, group) : 0
          return nil if scale.nil?

          scale = MathFunctions.scale(scale) unless node.name == "ROUNDMAGIC"
          return MathFunctions.evaluate(node.name, value, type, scale, type_of(node.arguments.first))
        end
        if ArrayFunctions::ARITIES.key?(node.name)
          return ArrayFunctions.evaluate(node.name, type_of(node.arguments.first),
            ->(index) { evaluate(node.arguments[index], row, group) },
            ->(a, b, element) { value_equals(a, b, left_type: element, right_type: type_of(node.arguments[1])) })
        end

        if %w[COALESCE IFNULL].include?(node.name)
          node.arguments.each do |argument|
            value = evaluate(argument, row, group)
            return function_type(node).convert(value, cast: true, source_type: type_of(argument), context: context) unless value.nil?
          end
          return nil
        end
        if node.name == "MOD"
          return modulus(node, row, group)
        end
        values = node.arguments.map { evaluate(it, row, group) }
        first, second = values
        if node.name == "NULLIF"
          return nil if equals(first, second) == true

          return first
        end
        return nil if values.any?(&:nil?)
        return DateTimeFunctions.evaluate(node.name, *values, context: context) if DateTimeFunctions::NAMES.include?(node.name)
        return CalendarFunctions.evaluate(node.name, *values, context: context) if CalendarFunctions::NAMES.include?(node.name)

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
        when "ABS"
          return first.abs if first.is_a?(DecfloatValue)

          return type_of(node).convert(first.abs) if first.is_a?(Float)

          first.is_a?(IntervalValue) ? (first.negative ? first.negate : first) : check_integer(numeric(first).abs, node)
        when "SIGN"
          return first.signum if first.is_a?(DecfloatValue)
          return first.absolute <=> 0 if first.is_a?(IntervalValue)
          raise Error.new(50100, "SIGN is unavailable for this value type") unless first.is_a?(Numeric)

          first.respond_to?(:nan?) && first.nan? ? 0 : first <=> 0
        end
      end

      def modulus(node, row, group)
        first = evaluate(node.arguments.first, row, group)
        return nil if first.nil?

        second = evaluate(node.arguments.last, row, group)
        return nil if second.nil?

        sources = node.arguments.map { type_of(it) }
        common = Type.common(sources)
        result = if FloatingOperations::NAMES.include?(common.name)
          FloatingOperations.evaluate("%", FloatingOperations.type(common), sources, ->(index) { index.zero? ? first : second })
        else
          first, second = [first,second].zip(sources).map { |value, source| common.coerce(value, source_type: source) }
          raise Error.new(22012, "Division by zero") if second.zero?

          first.remainder(second)
        end
        function_type(node).coerce(result, source_type: common)
      end

      def aggregate(node, group)
        group = group.select { boolean(evaluate(node.filter, it)) == true } if node.is_a?(Aggregate) && node.filter
        if node.name == "ARRAY_AGG"
          return ArrayAggregation.evaluate(node, group, self, aggregate_order(node))
        end
        argument = node.arguments.first
        return group.size if argument.is_a?(Star)

        values = group.map { evaluate(argument, it) }.compact
        if node.distinct
          values = values.uniq { Temporal.comparison_key(it) }
          values.sort! { compare(_1, _2) } if FloatingOperations::NAMES.include?(type_of(argument).name)
        end
        return values.length if node.name == "COUNT"
        return nil if values.empty?
        if %w[SUM AVG].include?(node.name) && function_type(node).name == "DECFLOAT"
          type = function_type(node)
          values = values.map { DecfloatValue.convert(it, source_type: type_of(argument)) }
          if node.name == "AVG" && values.any? { !it.finite? }
            raise Error.new(22018, "Non-finite DECFLOAT cannot convert to NUMERIC for AVG")
          end
          sum = values.reduce { _1.add(_2) }
          return node.name == "SUM" ? sum : sum.divide(DecfloatValue.parse(values.length.to_s), type.precision)
        end
        if %w[SUM AVG].include?(node.name) && Intervals.name?(type_of(argument).name)
          type = function_type(node)
          qualifier = Intervals.qualifier(type)
          if node.name == "SUM"
            value = values.reduce(nil) { |sum, item| sum ? IntervalValue.from_absolute(qualifier, sum.absolute + item.absolute) : Intervals.convert(item, qualifier) }
          else
            value = IntervalValue.from_absolute(qualifier, IntervalUnits.divide(values.sum(&:absolute), values.length))
          end
          return value.round(type)
        end

        case node.name
        when "SUM"
          return FloatingOperations.sum(values) if type_of(argument).name == "REAL"

          values.sum { numeric(it) }
        when "AVG"
          type = type_of(argument)
          if type && %w[BIGINT NUMERIC].include?(type.name)
            sum = values.sum { BigDecimal(numeric(it).to_s) }
            sum.div(BigDecimal(values.length.to_s), [sum.precision + 20, 40].max)
              .round((type.scale || 0) + 10, BigDecimal::ROUND_HALF_DOWN)
          else
            Type.new("DOUBLE", 53, nil).convert(FloatingOperations.sum(values) / values.length)
          end
        when "MIN" then values.min { compare(_1, _2) }
        when "MAX" then values.max { compare(_1, _2) }
        end
      end

      def aggregate_order(node)
        node.order.reject do |ordering|
          next false unless constant?(ordering.expression)

          evaluate(ordering.expression)
          true
        end
      end
    end
  end
end

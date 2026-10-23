# frozen_string_literal: true

module H2
  module SQL
    class QueryPlan
      attr_reader :columns, :types, :outer_bindings

      def initialize(statement, parameters, queries, sources, outer_scope)
        @statement, @parameters, @queries, @sources = statement, parameters, queries, sources
        @outer_scope = outer_scope
        @bounds = Evaluator.new(parameters, queries: queries)
        @bounds.validate(statement.limit)
        @bounds.validate(statement.offset)
      end

      def distinct_if_possible(outer_row)
        rows = execute(outer_row).rows
        return rows if @statement.limit || @statement.offset

        RowSet.new(rows, types, @bounds).rows(preserve_order: !@statement.order.empty?)
      end

      def constant?
        @order.empty? && [@statement.limit, @statement.offset].all? { it.nil? || @bounds.constant_expression?(it) }
      end

      def recursive_parts
        nil
      end

      private

      def matches?(evaluator, expression, row, group = nil)
        expression.nil? || evaluator.boolean(evaluator.evaluate(expression, row, group)) == true
      end

      def result(rows)
        Result.new(columns: columns, types: types, rows: rows)
      end

      def count_only?(statement, projections)
        !statement.where && statement.group.empty? && !statement.having && projections.all? do |projection|
          node = projection.expression
          node.is_a?(Function) && node.name == "COUNT" && node.arguments.first.is_a?(Star)
        end
      end

      def expand_stars(projections, scope)
        projections.flat_map do |projection|
          node = projection.expression
          next projection unless node.is_a?(Star)
          columns = scope.star(node.qualifier)
          if columns.empty?
            raise Error.new(42122, "Cannot resolve #{node.qualifier}.*")
          end

          columns.map { Projection.new(BoundColumn.new(it), it.name) }
        end
      end

      def resolve_order(order, projections)
        aliases = projections.to_h { [it.label || label(it.expression), it.expression] }
        order.map do |ordering|
          node = ordering.expression
          expression = if ordering.position
            index, descending = order_position(ordering, projections.length)
            ordering = ordering.with(descending: descending)
            projections.fetch(index).expression
          else
            resolve_alias(node, aliases)
          end
          ordering.with(expression: expression)
        end
      end

      def order_position(ordering, width)
        value = @bounds.evaluate(ordering.expression)
        index = value.nil? ? 1 : Type.new("INTEGER", nil, nil).convert(value)
        unless (1..width).cover?(index.abs)
          raise Error.new(90068, "Invalid ORDER BY position #{index}")
        end
        [index.abs - 1, index.negative? ? !ordering.descending : ordering.descending]
      end

      def resolve_alias(node, aliases)
        case node
        when ColumnRef then node.qualifier ? node : aliases.fetch(node.name, node)
        when Unary then node.with(operand: resolve_alias(node.operand, aliases))
        when Binary, IntervalDifference then node.with(left: resolve_alias(node.left, aliases), right: resolve_alias(node.right, aliases))
        when Predicate, Function then node.with(arguments: node.arguments.map { resolve_alias(it, aliases) })
        when Cast then node.with(expression: resolve_alias(node.expression, aliases))
        when TimeZoneExpression then node.with(expression: resolve_alias(node.expression, aliases), zone: node.zone && resolve_alias(node.zone, aliases))
        when ArrayConstructor then node.with(expressions: node.expressions.map { resolve_alias(it, aliases) })
        when ArrayElement then node.with(array: resolve_alias(node.array, aliases), index: resolve_alias(node.index, aliases))
        else node
        end
      end

      def ordered(entries, order, evaluator)
        return entries if order.empty?

        keyed = entries.each_with_index.map do |entry, index|
          keys = order.map { evaluator.evaluate(it.expression, entry[1], entry[2]) }
          [entry, keys, index]
        end
        keyed.sort! do |left, right|
          comparison = 0
          order.each_with_index do |ordering, index|
            a, b = left[1][index], right[1][index]
            if a.nil? || b.nil?
              nulls_first = ordering.nulls ? ordering.nulls == :first : !ordering.descending
              comparison = a.nil? && b.nil? ? 0 : (a.nil? == nulls_first ? -1 : 1)
            else
              comparison = evaluator.compare(a, b)
              comparison = -comparison if ordering.descending
            end
            break unless comparison.zero?
          end
          comparison.zero? ? left[2] <=> right[2] : comparison
        end
        keyed.map(&:first)
      end

      def paginate(entries, limit, offset, outer_row = {})
        evaluator = @bounds
        count = lambda do |node|
          evaluator.validate(node)
          value = evaluator.evaluate(node, outer_row)
          value = Type.new("BIGINT", nil, nil).convert(value)
          raise Error.new(90008, "Invalid row count #{value.inspect}") if value.nil? || value.negative?

          value
        end
        entries = entries.drop(count.call(offset)) if offset
        entries = entries.first(count.call(limit)) if limit
        entries
      end

      def label(node, inside: false)
        Formatter.expression(@evaluator.optimized_expression(node), inside: inside)
      end
    end

    class SelectPlan < QueryPlan
      def initialize(statement, parameters, queries, sources, outer_scope)
        super
        @source = sources.prepare(statement.source, outer_scope: outer_scope)
        @scope = @source.scope(outer_scope)
        @evaluator = Evaluator.new(parameters, scope: @scope, queries: queries)
        @projections = expand_stars(statement.projections, @scope)
        @projections.each { @evaluator.validate(it.expression, aggregates: true) }
        @evaluator.validate(statement.where)
        statement.group.each { @evaluator.validate(it) }
        @evaluator.validate(statement.having, aggregates: true)
        @order = resolve_order(statement.order, @projections)
        @order.each { @evaluator.validate(it.expression, aggregates: true) }
        @grouped = !statement.group.empty? || ([statement.having] + @projections.map(&:expression) + @order.map(&:expression)).any? do
          @evaluator.contains_aggregate?(it)
        end
        if @grouped
          (@projections.map(&:expression) + [statement.having] + @order.map(&:expression)).each do
            @evaluator.validate_grouping(it, statement.group)
          end
        elsif statement.having
          raise Error.new(90016, "HAVING requires grouped expressions")
        end
        @columns = @projections.map { it.label || label(it.expression) }.freeze
        @types = @projections.map { @evaluator.type_of(it.expression) }.freeze
        @outer_bindings = (@source.outer_bindings + @evaluator.outer_bindings + @bounds.outer_bindings).uniq.reject { @scope.local?(it) }.freeze
      end

      def execute(outer_row = {}, max_rows: nil)
        statement = @statement
        evaluator = @evaluator
        rows = @source.rows(outer_row).lazy.map { outer_row.merge(it) }
        pagination_applied = false
        groups = if count_only?(statement, @projections) && !rows.size.nil?
          [rows]
        else
          input = rows.select { matches?(evaluator, statement.where, it) }
          if !@grouped && @order.empty? && !statement.distinct
            input = paginate(input, statement.limit, statement.offset, outer_row)
            input = input.first(max_rows) if max_rows
            pagination_applied = true
          end
          input = input.to_a
          if !statement.group.empty?
            input.group_by { |row| statement.group.map { Temporal.comparison_key(evaluator.evaluate(it, row)) } }.values
          elsif @grouped
            [input]
          else
            input.map { [it] }
          end
        end
        entries = groups.filter_map do |group|
          row = group.first || outer_row.merge(@source.bindings.to_h { [it.key, nil] })
          evaluator.validate_group_correlations(group)
          next unless matches?(evaluator, statement.having, row, group)

          projected = @projections.map { evaluator.evaluate(it.expression, row, group) }
          [projected, row, group]
        end
        entries = entries.uniq { |entry| entry.first.map { Temporal.comparison_key(it) } } if statement.distinct
        entries = ordered(entries, @order, evaluator)
        entries = paginate(entries, statement.limit, statement.offset, outer_row) unless pagination_applied
        entries = entries.first(max_rows) if max_rows
        result(entries.map(&:first))
      end

      def constant?
        super && !@statement.source && !@statement.where && !@grouped && !@statement.having &&
          @projections.all? { @evaluator.constant_expression?(it.expression) }
      end
    end

    class ValuesPlan < QueryPlan
      def initialize(statement, parameters, queries, sources, outer_scope)
        super
        width = statement.rows.first.length
        unless statement.rows.all? { it.length == width }
          raise Error.new(21002, "Column count does not match")
        end
        @evaluator = Evaluator.new(parameters, scope: Scope.new([], parent: outer_scope), queries: queries)
        statement.rows.flatten.each { @evaluator.validate(it) }
        @types = Array.new(width) do |index|
          type = Type.common(statement.rows.map { @evaluator.type_of(it[index]) })
          type.name == "UNKNOWN" ? Type.new("VARCHAR", nil, nil) : type
        end.freeze
        @columns = Array.new(width) { "C#{it + 1}" }.freeze
        @bindings = columns.each_with_index.map { |name, index| ColumnBinding.new(name, nil, types[index], Object.new.freeze) }
        scope = Scope.new(@bindings, parent: outer_scope)
        @ordering_evaluator = Evaluator.new(parameters, scope: scope, queries: queries)
        projections = @bindings.map { Projection.new(BoundColumn.new(it), it.name) }
        @order = resolve_order(statement.order, projections)
        @order.each { @ordering_evaluator.validate(it.expression) }
        @outer_bindings = (@evaluator.outer_bindings + @ordering_evaluator.outer_bindings + @bounds.outer_bindings).uniq.freeze
      end

      def execute(outer_row = {}, max_rows: nil)
        entries = @statement.rows.lazy.map do |expressions|
          row = expressions.each_with_index.map { |expression, index| types[index].convert(@evaluator.evaluate(expression, outer_row), cast: true, source_type: @evaluator.type_of(expression), context: @evaluator.context) }
          context = outer_row.merge(@bindings.each_with_index.to_h { |binding, index| [binding.key, row[index]] })
          [row, context, nil]
        end
        entries = ordered(entries.to_a, @order, @ordering_evaluator) unless @order.empty?
        entries = paginate(entries, @statement.limit, @statement.offset, outer_row)
        entries = entries.first(max_rows) if max_rows
        result(entries.map(&:first))
      end

      def constant?
        super && @statement.rows.flatten.all? { @evaluator.constant_expression?(it) }
      end
    end

    module Formatter
      module_function

      def expression(node, inside: false)
        case node
        when CurrentDateTime then node.name + (node.scale.nil? ? "" : "(#{node.scale})")
        when DecimalLiteral then ArrayType.decimal_text(node.value, node.scale)
        when TypedLiteral
          if node.value.nil? && node.type.name == "BOOLEAN"
            "UNKNOWN"
          elsif node.value.is_a?(BigDecimal) && node.type.name == "NUMERIC"
            text = ArrayType.decimal_text(node.value, node.type.scale)
            node.cast ? "CAST(#{text} AS #{SQLTypeName.format(node.type)})" : text
          else
            expression(node.cast ? Cast.new(Literal.new(node.value), node.type) : Literal.new(node.value), inside: inside)
          end
        when TimeZoneExpression then "#{expression(node.expression, inside: true)} AT #{node.zone ? "TIME ZONE #{expression(node.zone, inside: true)}" : 'LOCAL'}"
        when BoundColumn then node.binding.name
        when ColumnRef then inside && node.qualifier ? "#{node.qualifier}.#{node.name}" : node.name
        when Literal
          case node.value
          when nil then "NULL"
          when true then "TRUE"
          when false then "FALSE"
          when String then BinaryString.binary?(node.value) ? "X'#{node.value.unpack1('H*')}'" : "'#{node.value.gsub("'", "''")}'"
          when UUIDValue then "UUID '#{node.value}'"
          when IntervalValue then node.value.to_s
          when DateValue, TimeValue, TimestampValue, TimeTimeZoneValue, TimestampTimeZoneValue then "#{Temporal.name(node.value)} '#{node.value}'"
          when BigDecimal then node.value.to_s("F")
          when ArrayValue
            items = node.value.values.map do |value|
              literal = value.is_a?(BigDecimal) ? TypedLiteral.new(value, node.value.element_type, false) : Literal.new(value)
              expression(literal, inside: true)
            end
            "ARRAY [#{items.join(', ')}]"
          when RowValue then "ROW (#{node.value.values.map { expression(Literal.new(it), inside: true) }.join(', ')})"
          else node.value.to_s
          end
        when Parameter then "?#{node.index + 1}"
        when Star then "*"
        when Function
          if node.name == "EXTRACT"
            "EXTRACT(#{node.arguments.first.value} FROM #{expression(node.arguments.last, inside: true)})"
          elsif DateTimeFunctions::NAMES.include?(node.name) || node.name == "DATE_TRUNC"
            "#{node.name}(#{node.arguments.first.value}, #{node.arguments.drop(1).map { expression(it, inside: true) }.join(', ')})"
          else
            "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { expression(it, inside: true) }.join(', ')})"
          end
        when Binary then "#{expression(node.left, inside: true)} #{node.operator} #{expression(node.right, inside: true)}"
        when IntervalDifference then "(#{expression(node.left, inside: true)} - #{expression(node.right, inside: true)}) #{Intervals.sql(node.type).delete_prefix('INTERVAL ')}"
        when Unary then "#{node.operator} #{expression(node.operand, inside: true)}"
        when Cast
          type = node.type
          name = SQLTypeName.format(type)
          "CAST(#{expression(node.expression, inside: true)} AS #{name})"
        when RowConstructor then "ROW (#{node.expressions.map { expression(it, inside: true) }.join(', ')})"
        when ArrayConstructor then "ARRAY [#{node.expressions.map { expression(it, inside: true) }.join(', ')}]"
        when ArrayElement then "#{expression(node.array, inside: true)}[#{expression(node.index, inside: true)}]"
        when ArrayQuery then "ARRAY (#{query(node.query)})"
        when Subquery then "(#{query(node.query)})"
        when Exists then "EXISTS(#{query(node.query)})"
        when InQuery
          statement = node.query
          statement = statement.with(distinct: true) if statement.is_a?(Select) && !statement.limit && !statement.offset
          text = query(statement).lines.map { "    #{it}" }.join
          "#{expression(node.expression, inside: true)} IN(#{text})"
        when CaseExpression
          sql = node.operand ? "CASE #{expression(node.operand, inside: true)}" : "CASE"
          node.branches.each { |condition, value| sql += " WHEN #{expression(condition, inside: true)} THEN #{expression(value, inside: true)}" }
          sql + " ELSE #{expression(node.fallback, inside: true)} END"
        else "EXPRESSION"
        end
      end

      def query(node)
        case node
        when WithQuery
          definitions = node.definitions.map do |definition|
            name = definition.name
            name += "(#{definition.columns.join(', ')})" if definition.columns
            "#{name} AS (#{query(definition.query)})"
          end
          "WITH#{node.recursive ? ' RECURSIVE' : ''} #{definitions.join(', ')}\n#{query(node.query)}"
        when SetQuery
          operator = {union: "UNION", union_all: "UNION ALL", except: "EXCEPT", intersect: "INTERSECT"}.fetch(node.operator)
          operands = [node.left, node.right].map do |operand|
            if node.operator != :union_all && operand.is_a?(Select) && !operand.limit && !operand.offset
              operand = operand.with(distinct: true)
            end
            query(operand)
          end
          "(#{operands[0]})\n#{operator}\n(#{operands[1]})"
        when Values
          "VALUES " + node.rows.map { |row| "(#{row.map { expression(it, inside: true) }.join(', ')})" }.join(", ")
        when Select
          sql = "SELECT#{node.distinct ? ' DISTINCT' : ''}\n    " + node.projections.map do |projection|
            expression(projection.expression, inside: true) + (projection.label ? " AS #{projection.label}" : "")
          end.join(",\n    ")
          sql += "\nFROM #{source(node.source)}" if node.source
          sql += "\nWHERE #{expression(node.where, inside: true)}" if node.where
          sql
        end
      end

      def source(node)
        case node
        when TableSource then "PUBLIC.#{node.name}"
        when RangeSource then "#{node.name}(#{node.arguments.map { expression(it, inside: true) }.join(', ')})"
        when AliasedSource then "#{source(node.source)} #{node.name}"
        when DerivedSource then "(#{query(node.query)})"
        else "JOIN"
        end
      end
    end
  end
end

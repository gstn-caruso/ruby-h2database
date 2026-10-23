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
          expression = if node.is_a?(Literal) && node.value.is_a?(Integer)
            unless (1..projections.length).cover?(node.value)
              raise Error.new(90068, "Invalid ORDER BY position #{node.value}")
            end
            projections.fetch(node.value - 1).expression
          else
            resolve_alias(node, aliases)
          end
          ordering.with(expression: expression)
        end
      end

      def resolve_alias(node, aliases)
        case node
        when ColumnRef then node.qualifier ? node : aliases.fetch(node.name, node)
        when Unary then node.with(operand: resolve_alias(node.operand, aliases))
        when Binary then node.with(left: resolve_alias(node.left, aliases), right: resolve_alias(node.right, aliases))
        when Predicate, Function then node.with(arguments: node.arguments.map { resolve_alias(it, aliases) })
        when Cast then node.with(expression: resolve_alias(node.expression, aliases))
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
        Formatter.expression(node, inside: inside)
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
            input.group_by { |row| statement.group.map { evaluator.evaluate(it, row) } }.values
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
        entries = entries.uniq(&:first) if statement.distinct
        entries = ordered(entries, @order, evaluator)
        entries = paginate(entries, statement.limit, statement.offset, outer_row) unless pagination_applied
        entries = entries.first(max_rows) if max_rows
        result(entries.map(&:first))
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
        @types = Array.new(width) { |index| Type.common(statement.rows.map { @evaluator.type_of(it[index]) }) }.freeze
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
          row = expressions.each_with_index.map { |expression, index| types[index].convert(@evaluator.evaluate(expression, outer_row), cast: true, source_type: @evaluator.type_of(expression)) }
          context = outer_row.merge(@bindings.each_with_index.to_h { |binding, index| [binding.key, row[index]] })
          [row, context, nil]
        end
        entries = ordered(entries.to_a, @order, @ordering_evaluator) unless @order.empty?
        entries = paginate(entries, @statement.limit, @statement.offset, outer_row)
        entries = entries.first(max_rows) if max_rows
        result(entries.map(&:first))
      end
    end

    module Formatter
      module_function

      def expression(node, inside: false)
        case node
        when BoundColumn then node.binding.name
        when ColumnRef then inside && node.qualifier ? "#{node.qualifier}.#{node.name}" : node.name
        when Literal
          case node.value
          when nil then "NULL"
          when true then "TRUE"
          when false then "FALSE"
          when String then BinaryString.binary?(node.value) ? "X'#{node.value.unpack1('H*')}'" : "'#{node.value.gsub("'", "''")}'"
          when UUIDValue then "UUID '#{node.value}'"
          when BigDecimal then node.value.to_s("F")
          else node.value.to_s
          end
        when Parameter then "?#{node.index + 1}"
        when Star then "*"
        when Function then "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { expression(it, inside: true) }.join(', ')})"
        when Binary then "#{expression(node.left, inside: true)} #{node.operator} #{expression(node.right, inside: true)}"
        when Unary then "#{node.operator} #{expression(node.operand, inside: true)}"
        when Cast
          type = node.type
          name = type.name == "VARBINARY" ? "BINARY VARYING" : type.name
          name += "(#{type.precision})" if %w[BINARY VARBINARY].include?(type.name) && type.precision
          "CAST(#{expression(node.expression, inside: true)} AS #{name})"
        when RowConstructor then "ROW (#{node.expressions.map { expression(it, inside: true) }.join(', ')})"
        when Subquery then "(#{query(node.query)})"
        when Exists then "EXISTS(#{query(node.query)})"
        when InQuery then "#{expression(node.expression, inside: true)} IN(#{query(node.query)})"
        when CaseExpression
          sql = node.operand ? "CASE #{expression(node.operand, inside: true)}" : "CASE"
          node.branches.each { |condition, value| sql += " WHEN #{expression(condition, inside: true)} THEN #{expression(value, inside: true)}" }
          sql + " ELSE #{expression(node.fallback, inside: true)} END"
        else "EXPRESSION"
        end
      end

      def query(node)
        case node
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

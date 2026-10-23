# frozen_string_literal: true

module H2
  module SQL
    class Queries
      def initialize(catalog, parameters)
        @parameters = parameters
        @sources = Sources.new(catalog, parameters, self)
      end

      def execute(statement)
        case statement
        when Select then select(statement)
        when Values then values(statement)
        when Explain then explain(statement.statement)
        else raise Error.new(42000, "Expected query")
        end
      end

      private

      def matches?(evaluator, expression, row, group = nil)
        expression.nil? || evaluator.boolean(evaluator.evaluate(expression, row, group)) == true
      end

      def select(statement)
        source = @sources.resolve(statement.source)
        evaluator = Evaluator.new(@parameters, scope: source.scope)
        projections = expand_stars(statement.projections, source.scope)
        projections.each { evaluator.validate(it.expression, aggregates: true) }
        evaluator.validate(statement.where)
        statement.group.each { evaluator.validate(it) }
        evaluator.validate(statement.having, aggregates: true)
        order = resolve_order(statement.order, projections)
        order.each { evaluator.validate(it.expression, aggregates: true) }
        grouped = !statement.group.empty? || ([statement.having] + projections.map(&:expression) + order.map(&:expression)).any? do
          evaluator.contains_aggregate?(it)
        end
        if grouped
          (projections.map(&:expression) + [statement.having] + order.map(&:expression)).each do
            evaluator.validate_grouping(it, statement.group)
          end
        elsif statement.having
          raise Error.new(90016, "HAVING requires grouped expressions")
        end

        pagination_applied = false
        groups = if count_only?(statement, projections) && !source.rows.size.nil?
          [source.rows]
        else
          input = source.rows.lazy.select { matches?(evaluator, statement.where, it) }
          if !grouped && order.empty? && !statement.distinct
            input = paginate(input, statement.limit, statement.offset)
            pagination_applied = true
          end
          input = input.to_a
          if !statement.group.empty?
            input.group_by { |row| statement.group.map { evaluator.evaluate(it, row) } }.values
          elsif grouped
            [input]
          else
            input.map { [it] }
          end
        end
        entries = groups.filter_map do |group|
          row = group.first || {}
          next unless matches?(evaluator, statement.having, row, group)

          projected = projections.map { evaluator.evaluate(it.expression, row, group) }
          [projected, row, group]
        end
        entries = entries.uniq(&:first) if statement.distinct
        entries = ordered(entries, order, evaluator)
        entries = paginate(entries, statement.limit, statement.offset) unless pagination_applied
        Result.new(columns: projections.map { it.label || label(it.expression) }, rows: entries.map(&:first),
          types: projections.map { evaluator.type_of(it.expression) })
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

      def values(statement)
        width = statement.rows.first.length
        unless statement.rows.all? { it.length == width }
          raise Error.new(21002, "Column count does not match")
        end
        evaluator = Evaluator.new(@parameters)
        statement.rows.flatten.each { evaluator.validate(it) }
        types = Array.new(width) { |index| Type.common(statement.rows.map { evaluator.type_of(it[index]) }) }
        columns = Array.new(width) { Column.new("C#{it + 1}", types[it], true, nil) }
        projected = statement.rows.map do |row|
          row.each_with_index.map { |expression, index| types[index].convert(evaluator.evaluate(expression), cast: true) }
        end
        entries = projected.map { [it, columns.map(&:name).zip(it).to_h, nil] }
        ordering_evaluator = Evaluator.new(@parameters, columns)
        projections = columns.map { Projection.new(ColumnRef.new(it.name, nil), it.name) }
        order = resolve_order(statement.order, projections)
        order.each { ordering_evaluator.validate(it.expression) }
        entries = ordered(entries, order, ordering_evaluator)
        entries = paginate(entries, statement.limit, statement.offset)
        Result.new(columns: columns.map(&:name), rows: entries.map(&:first), types: types)
      end

      def explain(statement)
        unless statement.is_a?(Values) && statement.order.empty? && !statement.limit && !statement.offset
          raise Error.new(50100, "EXPLAIN for this statement has not yet been ported")
        end
        values(statement)
        plan = "VALUES " + statement.rows.map { |row| "(#{row.map { label(it) }.join(', ')})" }.join(", ")
        Result.new(columns: ["PLAN"], rows: [[plan]])
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

      def paginate(entries, limit, offset)
        evaluator = Evaluator.new(@parameters)
        count = lambda do |node|
          evaluator.validate(node)
          value = evaluator.evaluate(node)
          value = Type.new("BIGINT", nil, nil).convert(value)
          raise Error.new(90008, "Invalid row count #{value.inspect}") if value.nil? || value.negative?

          value
        end
        entries = entries.drop(count.call(offset)) if offset
        entries = entries.first(count.call(limit)) if limit
        entries
      end

      def label(node, inside: false)
        case node
        when BoundColumn then node.binding.name
        when ColumnRef then inside && node.qualifier ? "#{node.qualifier}.#{node.name}" : node.name
        when Literal
          case node.value
          when nil then "NULL"
          when true then "TRUE"
          when false then "FALSE"
          when String then "'#{node.value.gsub("'", "''")}'"
          when BigDecimal then node.value.to_s("F")
          else node.value.to_s
          end
        when Parameter then "?#{node.index + 1}"
        when Star then "*"
        when Function then "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { label(it, inside: true) }.join(', ')})"
        when Binary then "#{label(node.left, inside: true)} #{node.operator} #{label(node.right, inside: true)}"
        when Unary then "#{node.operator} #{label(node.operand, inside: true)}"
        when Cast then "CAST(#{label(node.expression, inside: true)} AS #{node.type.name})"
        else "EXPRESSION"
        end
      end
    end
  end
end

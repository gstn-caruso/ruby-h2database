# frozen_string_literal: true

module H2
  module SQL
    class Executor
      attr_reader :changes

      def initialize(catalog, parameters)
        @catalog = catalog
        @parameters = parameters
        @changes = {}
      end

      def execute(statement)
        case statement
        when Select then select(statement)
        when Values then values(statement)
        when Explain then explain(statement.statement)
        when CreateTable then create(statement)
        when DropTable
          table(statement.name) unless statement.if_exists
          @changes[statement.name] = nil
          Result.new(update_count: 0)
        when Truncate
          target = table(statement.name).copy
          target.rows.clear
          change(target, 0)
        when Insert then insert(statement)
        when Update then update(statement)
        when Delete then delete(statement)
        else raise Error.new(50100, "Statement not yet ported")
        end
      end

      private

      def table(name)
        @catalog.fetch(name) { raise Error.new(42102, "Table #{name} not found") }
      end

      def change(target, count)
        target.validate_constraints
        @changes[target.name] = target.seal
        Result.new(update_count: count)
      end

      def create(statement)
        if @catalog.key?(statement.name)
          return Result.new(update_count: 0) if statement.if_not_exists

          raise Error.new(42101, "Table #{statement.name} already exists")
        end
        evaluator = Evaluator.new(@parameters)
        columns = statement.columns.map do |column|
          evaluator.validate(column.default)
          column.default ? column.with(default: Literal.new(evaluator.evaluate(column.default))) : column
        end
        change(Table.new(statement.name, columns, statement.keys), 0)
      end

      def insert(statement)
        target = table(statement.table).copy
        names = statement.columns || target.columns.map(&:name)
        target.validate_columns(names)
        evaluator = Evaluator.new(@parameters)
        statement.rows.each do |expressions|
          if expressions && expressions.length != names.length
            raise Error.new(21002, "Column count does not match")
          end
          supplied = expressions ? names.zip(expressions).to_h : {}
          row = target.columns.to_h do |column|
            expression = supplied.fetch(column.name, Default.new)
            expression = column.default if expression.is_a?(Default)
            evaluator.validate(expression)
            [column.name, expression ? evaluator.evaluate(expression) : nil]
          end
          target.rows << target.convert_row(row)
        end
        change(target, statement.rows.length)
      end

      def update(statement)
        target = table(statement.table).copy
        target.validate_columns(statement.assignments.map(&:first))
        evaluator = Evaluator.new(@parameters, target.columns, [target.name])
        assignments = statement.assignments.map do |name, expression|
          if expression.is_a?(Default)
            expression = target.columns.find { it.name == name }.default || Literal.new(nil)
          end
          evaluator.validate(expression)
          [name, expression]
        end
        evaluator.validate(statement.where)
        count = 0
        target.rows.map! do |row|
          next row unless matches?(evaluator, statement.where, row)

          values = assignments.to_h { |name, expression| [name, evaluator.evaluate(expression, row)] }
          count += 1
          target.convert_row(row.merge(values))
        end
        change(target, count)
      end

      def delete(statement)
        target = table(statement.table).copy
        evaluator = Evaluator.new(@parameters, target.columns, [target.name])
        evaluator.validate(statement.where)
        before = target.rows.length
        target.rows.reject! { matches?(evaluator, statement.where, it) }
        change(target, before - target.rows.length)
      end

      def matches?(evaluator, expression, row, group = nil)
        expression.nil? || evaluator.boolean(evaluator.evaluate(expression, row, group)) == true
      end

      def select(statement)
        source = statement.table ? table(statement.table) : nil
        columns = source ? source.columns : []
        qualifiers = [statement.alias_name || statement.table]
        evaluator = Evaluator.new(@parameters, columns, qualifiers)
        projections = expand_stars(statement.projections, columns, qualifiers)
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

        input = (source ? source.rows : [{}]).select { matches?(evaluator, statement.where, it) }
        groups = if !statement.group.empty?
          input.group_by { |row| statement.group.map { evaluator.evaluate(it, row) } }.values
        elsif grouped
          [input]
        else
          input.map { [it] }
        end
        entries = groups.filter_map do |group|
          row = group.first || {}
          next unless matches?(evaluator, statement.having, row, group)

          projected = projections.map { evaluator.evaluate(it.expression, row, group) }
          [projected, row, group]
        end
        entries = entries.uniq(&:first) if statement.distinct
        entries = ordered(entries, order, evaluator)
        entries = paginate(entries, statement.limit, statement.offset)
        Result.new(columns: projections.map { it.label || label(it.expression) }, rows: entries.map(&:first))
      end

      def expand_stars(projections, columns, qualifiers)
        projections.flat_map do |projection|
          node = projection.expression
          next projection unless node.is_a?(Star)
          if columns.empty? || (node.qualifier && !qualifiers.include?(node.qualifier))
            raise Error.new(42122, "Cannot resolve #{node.qualifier}.*")
          end

          columns.map { Projection.new(ColumnRef.new(it.name, nil), it.name) }
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
        columns = Array.new(width) { Column.new("C#{it + 1}", nil, true, nil) }
        projected = statement.rows.map { |row| row.map { evaluator.evaluate(it) } }
        entries = projected.map { [it, columns.map(&:name).zip(it).to_h, nil] }
        ordering_evaluator = Evaluator.new(@parameters, columns)
        projections = columns.map { Projection.new(ColumnRef.new(it.name, nil), it.name) }
        order = resolve_order(statement.order, projections)
        order.each { ordering_evaluator.validate(it.expression) }
        entries = ordered(entries, order, ordering_evaluator)
        entries = paginate(entries, statement.limit, statement.offset)
        Result.new(columns: columns.map(&:name), rows: entries.map(&:first))
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

      def label(node)
        case node
        when ColumnRef then node.name
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
        when Function then "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { label(it) }.join(', ')})"
        when Binary then "#{label(node.left)} #{node.operator} #{label(node.right)}"
        when Unary then "#{node.operator} #{label(node.operand)}"
        when Cast then "CAST(#{label(node.expression)} AS #{node.type.name})"
        else "EXPRESSION"
        end
      end
    end
  end
end

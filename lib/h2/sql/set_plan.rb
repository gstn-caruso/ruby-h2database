# frozen_string_literal: true

module H2
  module SQL
    class SetPlan < QueryPlan
      def initialize(statement, parameters, queries, sources, outer_scope)
        super
        @left = queries.prepare(statement.left, outer_scope: outer_scope)
        @right = queries.prepare(statement.right, outer_scope: outer_scope)
        unless @left.columns.length == @right.columns.length
          raise Error.new(21002, "Column count does not match")
        end
        @columns = @left.columns
        @types = @left.types.zip(@right.types).map { Type.common(it) }.freeze
        @bindings = columns.each_with_index.map { |name, index| ColumnBinding.new(name, nil, types[index], Object.new.freeze) }
        @evaluator = Evaluator.new(parameters, scope: Scope.new(@bindings), queries: queries)
        @order = prepare_order(statement.order)
        @outer_bindings = (@left.outer_bindings + @right.outer_bindings + @bounds.outer_bindings).uniq.freeze
      end

      def execute(outer_row = {}, max_rows: nil)
        left = convert_rows(@left.execute(outer_row).rows, @left.types)
        right_rows = @statement.operator == :intersect ? @right.distinct_if_possible(outer_row) : @right.execute(outer_row).rows
        right = convert_rows(right_rows, @right.types)
        rows = case @statement.operator
        when :union_all then left + right
        when :union then RowSet.new(left + right, types, @evaluator).rows
        when :except
          excluded = RowSet.new(right, types, @evaluator)
          RowSet.new(left, types, @evaluator).rows.reject { excluded.include?(it) }
        when :intersect
          included = RowSet.new(left, types, @evaluator)
          right.select { included.include?(it) }
        end
        entries = rows.map { |row| [row, @bindings.each_with_index.to_h { |binding, index| [binding.key, row[index]] }, nil] }
        entries = ordered(entries, @order, @evaluator)
        entries = paginate(entries, @statement.limit, @statement.offset, outer_row)
        entries = entries.first(max_rows) if max_rows
        result(entries.map(&:first))
      end

      def constant?
        super && @left.constant? && @right.constant?
      end

      def recursive_parts
        [@left, @right]
      end

      private

      def convert_rows(rows, source_types)
        rows.map { |row| row.each_with_index.map { |value, index| types[index].coerce(value, source_type: source_types[index], context: @evaluator.context) } }
      end

      def prepare_order(order)
        order.filter_map do |ordering|
          node = ordering.expression
          if ordering.position
            index, descending = order_position(ordering, columns.length)
            ordering.with(expression: BoundColumn.new(@bindings[index]), descending: descending)
          elsif node.is_a?(ColumnRef) && !node.qualifier && (index = columns.index(node.name))
            ordering.with(expression: BoundColumn.new(@bindings[index]))
          elsif order_constant?(node)
            nil
          else
            raise Error.new(90068, "Set query ORDER BY must reference an output column")
          end
        end
      end

      def order_constant?(node)
        case node
        when Literal, TypedLiteral then true
        when Unary then %w[+ -].include?(node.operator) && node.operand.is_a?(Literal)
        when Cast then order_constant?(node.expression)
        when RowConstructor then node.expressions.all? { order_constant?(it) }
        else false
        end
      end
    end
  end
end

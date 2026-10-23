# frozen_string_literal: true

module H2
  module SQL
    module ArrayAggregation
      module_function

      def evaluate(node, group, evaluator, order)
        argument = node.arguments.first
        type = evaluator.type_of(argument)
        entries = group.each_with_index.map do |row, index|
          [evaluator.evaluate(argument, row), order.map { evaluator.evaluate(it.expression, row) }, index]
        end
        if node.distinct
          entries = distinct(entries, type, evaluator)
          entries.each_with_index { |entry, index| entry[2] = index }
        end
        unless order.empty?
          entries.sort! do |a, b|
            ValueOrdering.compare(a[1], b[1], order, evaluator).then { it.zero? ? a[2] <=> b[2] : it }
          end
        end
        return nil if entries.empty?

        ArrayType.new(type, ArrayValue::MAX_CARDINALITY).convert(ArrayValue.new(entries.map(&:first), type), cast: true, context: evaluator.context)
      end

      def distinct(entries, type, evaluator)
        keyed = entries.map { |entry| [type.name == "NULL" ? entry[0] : type.coerce(entry[0], source_type: type, context: evaluator.context), entry] }
        keyed.sort! { |a, b| evaluator.compare(a[0], b[0], untyped: true).then { it.zero? ? a[1][2] <=> b[1][2] : it } }
        unique = []
        keyed.each { |entry| unique << entry if unique.empty? || !evaluator.compare(unique.last[0], entry[0], untyped: true).zero? }
        unique.map(&:last)
      end
    end
  end
end

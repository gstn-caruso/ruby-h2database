# frozen_string_literal: true

module H2
  module SQL
    module ValueOrdering
      module_function

      def compare(left, right, order, evaluator)
        order.each_with_index do |ordering, index|
          a, b = left[index], right[index]
          if a.nil? || b.nil?
            first = ordering.nulls ? ordering.nulls == :first : !ordering.descending
            result = a.nil? && b.nil? ? 0 : (a.nil? == first ? -1 : 1)
          else
            result = evaluator.compare(a, b, untyped: true)
            result = -result if ordering.descending
          end
          return result unless result.zero?
        end
        0
      end
    end
  end
end

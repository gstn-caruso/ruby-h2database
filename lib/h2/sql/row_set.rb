# frozen_string_literal: true

module H2
  module SQL
    class RowSet
      def initialize(rows, types, evaluator)
        @types, @evaluator = types, evaluator
        entries = rows.each_with_index.map { |row, index| [key(row), row, index] }
        entries.sort! { |a, b| compare(a[0], b[0]).then { it.zero? ? a[2] <=> b[2] : it } }
        @entries = []
        entries.each do |entry|
          @entries << entry if @entries.empty? || !compare(@entries.last[0], entry[0]).zero?
        end
      end

      def rows(preserve_order: false)
        entries = preserve_order ? @entries.sort_by(&:last) : @entries
        entries.map { it[1] }
      end

      def include?(row)
        value = key(row)
        index = @entries.bsearch_index { compare(it[0], value) >= 0 }
        !index.nil? && compare(@entries[index][0], value).zero?
      end

      private

      def key(row)
        row.each_with_index.map { |value, index| @types[index].coerce(value, source_type: @types[index], context: @evaluator.context) }
      end

      def compare(left, right)
        left.each_with_index do |value, index|
          comparison = @evaluator.compare(value, right[index])
          return comparison unless comparison.zero?
        end
        0
      end
    end
  end
end

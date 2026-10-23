# frozen_string_literal: true

module H2
  module SQL
    class CommonTable
      attr_reader :name

      def initialize(definition, recursive:)
        @definition, @name = definition, definition.name
        @preparing = recursive
        @referenced = false
        @columns = (definition.columns || []).map { Column.new(it, Type.new("VARCHAR", nil, nil), true, nil) }.freeze
      end

      def prepare(queries)
        @plan = queries.unbound.prepare(@definition.query)
        @preparing = false
        @columns = @plan.columns.each_with_index.map do |name, index|
          raise Error.new(50004, "Unknown CTE column type #{name}") if @plan.types[index].name == "UNKNOWN"

          Column.new(@definition.columns&.[](index) || name, @plan.types[index], true, nil)
        end.freeze
        duplicate = @columns.group_by(&:name).find { |_name, group| group.length > 1 }
        raise Error.new(42121, "Duplicate CTE column #{duplicate.first}") if duplicate

        @recursive = @referenced
        @plan = queries.prepare(@definition.query)
        self
      end

      def columns
        @referenced = true if @preparing
        @columns
      end

      def preparing?
        @preparing
      end

      def rows
        return @frontier if @frontier
        return @plan.execute.rows unless @recursive
        raise Error.new(50100, "Recursive references in the anchor are not yet ported") if @executing

        parts = @plan.recursive_parts
        raise Error.new(42001, "Recursive queries require a set query") unless parts

        @executing = true
        begin
          seed, step = parts
          @frontier = seed.execute.rows
          rows = @frontier.dup
          loop do
            @frontier = step.execute.rows
            break if @frontier.empty?

            rows.concat(@frontier)
          end
          rows
        ensure
          @frontier = nil
          @executing = false
        end
      end
    end
  end
end

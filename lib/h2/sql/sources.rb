# frozen_string_literal: true

module H2
  module SQL
    class Relation < Data.define(:bindings, :visible, :rows, :qualifiers)
      def scope
        Scope.new(bindings, visible: visible, qualifiers: qualifiers)
      end
    end

    class RangeRows
      include Enumerable

      def initialize(first, last, step, key)
        raise Error.new(90142, "SYSTEM_RANGE step must not be zero") if step.zero?

        @first, @last, @step, @key = first, last, step, key
      end

      def size
        delta = @last - @first
        return 0 if (@step.positive? && delta.negative?) || (@step.negative? && delta.positive?)

        delta / @step + 1
      end
      alias length size

      def each
        return enum_for(__method__) { size } unless block_given?

        @first.step(@last, @step) { yield({@key => it}) }
        self
      end
    end

    class Sources
      def initialize(catalog, parameters, queries)
        @catalog, @parameters, @queries = catalog, parameters, queries
      end

      def resolve(source)
        case source
        when nil then Relation.new([], [], [{}], [])
        when TableSource
          table = @catalog.fetch(source.name) { raise Error.new(42102, "Table #{source.name} not found") }
          bindings = table.columns.map { binding(it.name, source.name, it.type) }
          rows = table.rows.lazy.map do |row|
            bindings.to_h { [it.key, row.fetch(it.name)] }
          end
          Relation.new(bindings, bindings, rows, [source.name])
        when RangeSource then range(source)
        when DerivedSource
          result = @queries.execute(source.query)
          bindings = result.columns.each_with_index.map { |name, index| binding(name, nil, result.types[index]) }
          rows = result.rows.lazy.map { |row| bindings.each_with_index.to_h { |column, index| [column.key, row[index]] } }
          Relation.new(bindings, bindings, rows, [])
        when AliasedSource then rename(resolve(source.source), source.name, source.columns)
        when JoinSource then join(source)
        else raise Error.new(50100, "Table expression not yet ported")
        end
      end

      private

      def binding(name, qualifier, type)
        ColumnBinding.new(name, qualifier, type, Object.new.freeze)
      end

      def rename(relation, name, names)
        names ||= relation.visible.map(&:name)
        raise Error.new(21002, "Derived column count does not match") unless names.length == relation.visible.length
        duplicate = names.tally.find { |_column, count| count > 1 }
        raise Error.new(42121, "Duplicate column #{duplicate.first}") if duplicate

        bindings = names.each_with_index.map { |column, index| binding(column, name, relation.visible[index].type) }
        rows = relation.rows.lazy.map do |row|
          bindings.each_with_index.to_h { |column, index| [column.key, row.fetch(relation.visible[index].key)] }
        end
        Relation.new(bindings, bindings, rows, [name])
      end

      def range(source)
        unless %w[SYSTEM_RANGE GENERATE_SERIES].include?(source.name)
          raise Error.new(50100, "Table function #{source.name} not yet ported")
        end
        unless (2..3).cover?(source.arguments.length)
          raise Error.new(7001, "SYSTEM_RANGE requires two or three arguments")
        end
        evaluator = Evaluator.new(@parameters)
        type = Type.new("BIGINT", nil, 0)
        arguments = source.arguments.map do |argument|
          evaluator.validate(argument)
          type.convert(evaluator.evaluate(argument)) || 0
        end
        first, last, step = arguments
        column = binding("X", source.name, type)
        Relation.new([column], [column], RangeRows.new(first, last, step || 1, column.key), [source.name])
      end

      def join(source)
        left = resolve(source.left)
        right = resolve(source.right)
        duplicate = (left.qualifiers & right.qualifiers).first
        raise Error.new(42123, "Duplicate table alias #{duplicate}") if duplicate

        bindings = left.bindings + right.bindings
        qualifiers = left.qualifiers + right.qualifiers
        evaluator = Evaluator.new(@parameters, scope: Scope.new(bindings, visible: left.visible + right.visible, qualifiers: qualifiers))
        evaluator.validate(source.condition)
        names = source.natural ? left.visible.map(&:name) & right.visible.map(&:name) : source.using_columns.uniq

        pairs = names.map { [left.scope.resolve(ColumnRef.new(it, nil)), right.scope.resolve(ColumnRef.new(it, nil))] }
        common = pairs.map { source.kind == :right ? it.last : it.first }
        visible = common + left.visible.reject { names.include?(it.name) } + right.visible.reject { names.include?(it.name) }
        preserved, other = source.kind == :right ? [right, left] : [left, right]
        other_rows = other.rows.to_a
        null_row = other.bindings.to_h { [it.key, nil] }
        outer = [:left, :right].include?(source.kind)
        rows = preserved.rows.flat_map do |row|
          matches = other_rows.filter_map do |candidate|
            combined = row.merge(candidate)
            next unless join_matches?(source.condition, pairs, evaluator, combined)

            combined
          end
          matches.empty? && outer ? [row.merge(null_row)] : matches
        end
        Relation.new(bindings, visible, rows, qualifiers)
      end

      def join_matches?(condition, pairs, evaluator, row)
        return false if condition && evaluator.boolean(evaluator.evaluate(condition, row)) != true

        pairs.all? do |left, right|
          a, b = row.fetch(left.key), row.fetch(right.key)
          !a.nil? && !b.nil? && evaluator.compare(a, b).zero?
        end
      end
    end
  end
end

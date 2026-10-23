# frozen_string_literal: true

module H2
  module SQL
    class Relation < Data.define(:bindings, :visible, :qualifiers, :outer_bindings, :loader)
      def scope(parent = nil)
        Scope.new(bindings, visible: visible, qualifiers: qualifiers, parent: parent)
      end

      def rows(outer_row = {})
        loader.call(outer_row)
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

      def prepare(source, outer_scope: nil)
        case source
        when nil then Relation.new([], [], [], [], ->(_row) { [{}] })
        when TableSource
          if !@catalog.key?(source.name) && !source.qualified && (cte = @queries.cte(source.name))
            bindings = cte.columns.map { binding(it.name, source.name, it.type) }
            loader = ->(_row) { cte.rows.lazy.map { |row| bindings.each_with_index.to_h { |column, index| [column.key, row[index]] } } }
            return Relation.new(bindings, bindings, [source.name], [], loader)
          end
          table = @catalog.fetch(source.name) { raise Error.new(@catalog.empty? ? 42104 : 42102, "Table #{source.name} not found") }
          bindings = table.columns.map { binding(it.name, source.name, it.type) }
          loader = lambda do |_outer_row|
            table.rows.lazy.map { |row| bindings.to_h { [it.key, row.fetch(it.name)] } }
          end
          Relation.new(bindings, bindings, [source.name], [], loader)
        when RangeSource then range(source, outer_scope)
        when UnnestSource then unnest(source)
        when DerivedSource
          plan = @queries.prepare(source.query)
          bindings = plan.columns.each_with_index.map { |name, index| binding(name, nil, plan.types[index]) }
          loader = lambda do |_outer_row|
            plan.execute.rows.lazy.map { |row| bindings.each_with_index.to_h { |column, index| [column.key, row[index]] } }
          end
          Relation.new(bindings, bindings, [], plan.outer_bindings, loader)
        when AliasedSource then rename(prepare(source.source, outer_scope: outer_scope), source.name, source.columns)
        when JoinSource then join(source, outer_scope)
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
        loader = lambda do |outer_row|
          relation.rows(outer_row).lazy.map do |row|
            bindings.each_with_index.to_h { |column, index| [column.key, row.fetch(relation.visible[index].key)] }
          end
        end
        Relation.new(bindings, bindings, [name], relation.outer_bindings, loader)
      end

      def range(source, outer_scope)
        unless %w[SYSTEM_RANGE GENERATE_SERIES].include?(source.name)
          raise Error.new(50100, "Table function #{source.name} not yet ported")
        end
        unless (2..3).cover?(source.arguments.length)
          raise Error.new(7001, "SYSTEM_RANGE requires two or three arguments")
        end
        evaluator = Evaluator.new(@parameters, queries: @queries)
        source.arguments.each { evaluator.validate(it) }
        type = Type.new("BIGINT", nil, 0)
        column = binding("X", source.name, type)
        loader = lambda do |outer_row|
          arguments = source.arguments.map { type.convert(evaluator.evaluate(it, outer_row)) || 0 }
          first, last, step = arguments
          RangeRows.new(first, last, step || 1, column.key)
        end
        Relation.new([column], [column], [source.name], evaluator.outer_bindings, loader)
      end

      def unnest(source)
        raise Error.new(7001, "UNNEST requires at least one argument") if source.arguments.empty?

        evaluator = Evaluator.new(@parameters, queries: @queries)
        source.arguments.each { evaluator.validate(it) }
        columns = source.types.each_with_index.map { |type, index| binding("C#{index + 1}", "UNNEST", type) }
        columns << binding("NORD", "UNNEST", Type.new("INTEGER", nil, 0)) if source.ordinality
        loader = lambda do |outer_row|
          arrays = source.arguments.map do |argument|
            value = evaluator.evaluate(argument, outer_row)
            if value.is_a?(JsonValue)
              value.elements
            else
              value.nil? ? [] : (value.is_a?(ArrayValue) || value.is_a?(RowValue) ? value.values : [value])
            end
          end
          (0...arrays.map(&:length).max).lazy.map do |index|
            values = arrays.map { it[index] }
            values << index + 1 if source.ordinality
            columns.each_with_index.to_h { |column, position| [column.key, values[position]] }
          end
        end
        Relation.new(columns, columns, ["UNNEST"], evaluator.outer_bindings, loader)
      end

      def join(source, outer_scope)
        left = prepare(source.left, outer_scope: outer_scope)
        right = prepare(source.right, outer_scope: outer_scope)
        duplicate = (left.qualifiers & right.qualifiers).first
        raise Error.new(42123, "Duplicate table alias #{duplicate}") if duplicate

        bindings = left.bindings + right.bindings
        qualifiers = left.qualifiers + right.qualifiers
        scope = Scope.new(bindings, visible: left.visible + right.visible, qualifiers: qualifiers, parent: outer_scope)
        evaluator = Evaluator.new(@parameters, scope: scope, queries: @queries)
        evaluator.validate(source.condition)
        names = source.natural ? left.visible.map(&:name) & right.visible.map(&:name) : source.using_columns.uniq
        pairs = names.map { [left.scope.resolve(ColumnRef.new(it, nil)), right.scope.resolve(ColumnRef.new(it, nil))] }
        common = pairs.map { source.kind == :right ? it.last : it.first }
        visible = common + left.visible.reject { names.include?(it.name) } + right.visible.reject { names.include?(it.name) }
        preserved, other = source.kind == :right ? [right, left] : [left, right]
        outer = [:left, :right].include?(source.kind)
        null_row = other.bindings.to_h { [it.key, nil] }
        loader = lambda do |outer_row|
          other_rows = other.rows(outer_row).to_a
          preserved.rows(outer_row).lazy.flat_map do |row|
            matches = other_rows.filter_map do |candidate|
              combined = row.merge(candidate)
              next unless join_matches?(source.condition, pairs, evaluator, outer_row.merge(combined))

              combined
            end
            matches.empty? && outer ? [row.merge(null_row)] : matches
          end
        end
        free = (left.outer_bindings + right.outer_bindings + evaluator.outer_bindings).uniq
        Relation.new(bindings, visible, qualifiers, free, loader)
      end

      def join_matches?(condition, pairs, evaluator, row)
        return false if condition && evaluator.boolean(evaluator.evaluate(condition, row)) != true

        pairs.all? do |left, right|
          a, b = row.fetch(left.key), row.fetch(right.key)
          evaluator.equals(a, b) == true
        end
      end
    end
  end
end

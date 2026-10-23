# frozen_string_literal: true

module H2
  module SQL
    class Executor
      attr_reader :changes

      def initialize(catalog, parameters)
        @catalog = catalog
        @parameters = parameters
        @changes = {}
        @queries = Queries.new(catalog, parameters)
      end

      def execute(statement)
        case statement
        when Select, Values, Explain then @queries.execute(statement)
        when CreateTable then create(statement)
        when DropTable
          statement.names.each { table(it) } unless statement.if_exists
          validate_drop_dependencies(statement.names)
          statement.names.each { @changes[it] = nil }
          Result.new(update_count: 0)
        when Truncate
          target = table(statement.name).copy
          count = target.rows.length
          target.truncate
          change(target, count)
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

      def validate_drop_dependencies(names)
        remaining = @catalog.reject { |name, _table| names.include?(name) }
        remaining.each_value do |table|
          table.columns.each do |column|
            default = column.default
            next unless default

            expression, parameters = default.is_a?(CapturedExpression) ? [default.expression, default.parameters] : [default, []]
            evaluator = Evaluator.new(parameters, queries: Queries.new(remaining, parameters))
            evaluator.validate(expression)
          rescue Error => error
            raise unless error.code == 42102

            raise Error.new(90107, "Cannot drop table because #{table.name} depends on it")
          end
        end
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
        evaluator = Evaluator.new(@parameters, queries: @queries)
        columns = statement.columns.map do |column|
          evaluator.validate(column.default)
          next column unless column.default

          default = if evaluator.contains_subquery?(column.default)
            CapturedExpression.new(column.default, @parameters.dup.freeze)
          elsif %w[BINARY VARBINARY].include?(column.type.name)
            evaluator.evaluate(column.default)
            CapturedExpression.new(column.default, @parameters.dup.freeze)
          else
            Literal.new(evaluator.evaluate(column.default))
          end
          column.with(default: default)
        end
        if statement.query
          result = @queries.execute(statement.query)
          if columns.empty?
            columns = result.columns.each_with_index.map do |name, index|
              type = result.types[index]
              raise Error.new(50100, "Cannot infer type for #{name}") unless type
              type = type.with(precision: 1) if type.name == "VARBINARY" && type.precision == 0

              Column.new(name, type, true, nil)
            end
          end
          raise Error.new(21002, "Column count does not match query") unless columns.length == result.columns.length
        end
        target = Table.new(statement.name, columns, statement.keys)
        if result && statement.with_data
          source_types = columns.map(&:name).zip(result.types).to_h
          result.rows.each { target.rows << target.convert_row(columns.map(&:name).zip(it).to_h, source_types: source_types) }
        end
        change(target, 0)
      end

      def insert(statement)
        target = table(statement.table).copy
        names = statement.columns || target.columns.map(&:name)
        target.validate_columns(names)
        evaluator = Evaluator.new(@parameters, queries: @queries)
        source_rows = if statement.query
          result = @queries.execute(statement.query)
          raise Error.new(21002, "Column count does not match query") unless result.columns.length == names.length

          result.rows.map { |row| row.map { Literal.new(it) } }
        else
          statement.rows
        end
        source_rows.each do |expressions|
          if expressions && expressions.length != names.length
            raise Error.new(21002, "Column count does not match")
          end
          supplied = expressions ? names.zip(expressions).to_h : {}
          source_types = {}
          row = target.columns.to_h do |column|
            expression = supplied.fetch(column.name, Default.new)
            expression, value_evaluator = expression.is_a?(Default) ? default_expression(column, evaluator) : [expression, evaluator]
            value_evaluator.validate(expression)
            source_types[column.name] = if result && supplied.key?(column.name) && !supplied[column.name].is_a?(Default)
              result.types[names.index(column.name)]
            else
              value_evaluator.type_of(expression)
            end
            [column.name, value_evaluator.evaluate(expression)]
          end
          target.rows << target.convert_row(row, source_types: source_types)
        end
        change(target, source_rows.length)
      end

      def update(statement)
        target = table(statement.table).copy
        target.validate_columns(statement.assignments.map(&:first))
        evaluator = Evaluator.new(@parameters, target.columns, [target.name], queries: @queries)
        assignments = statement.assignments.map do |name, expression|
          column = target.columns.find { it.name == name }
          expression, value_evaluator = expression.is_a?(Default) ? default_expression(column, evaluator) : [expression, evaluator]
          value_evaluator.validate(expression)
          [name, expression, value_evaluator]
        end
        evaluator.validate(statement.where)
        source_types = assignments.to_h { |name, expression, value_evaluator| [name, value_evaluator.type_of(expression)] }
        count = 0
        target.rows.map! do |row|
          next row unless matches?(evaluator, statement.where, row)

          values = assignments.to_h { |name, expression, value_evaluator| [name, value_evaluator.evaluate(expression, row)] }
          count += 1
          target.convert_row(row.merge(values), existing_row: row, source_types: source_types)
        end
        change(target, count)
      end

      def delete(statement)
        target = table(statement.table).copy
        evaluator = Evaluator.new(@parameters, target.columns, [target.name], queries: @queries)
        evaluator.validate(statement.where)
        before = target.rows.length
        target.rows.reject! { matches?(evaluator, statement.where, it) }
        change(target, before - target.rows.length)
      end

      def matches?(evaluator, expression, row, group = nil)
        expression.nil? || evaluator.boolean(evaluator.evaluate(expression, row, group)) == true
      end

      def default_expression(column, evaluator)
        default = column.default
        return [default || Literal.new(nil), evaluator] unless default.is_a?(CapturedExpression)

        queries = Queries.new(@catalog, default.parameters)
        [default.expression, Evaluator.new(default.parameters, queries: queries)]
      end
    end
  end
end

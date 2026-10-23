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
          statement.names.each { @changes[it] = nil }
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
        if statement.query
          result = @queries.execute(statement.query)
          if columns.empty?
            columns = result.columns.each_with_index.map do |name, index|
              type = result.types[index]
              raise Error.new(50100, "Cannot infer type for #{name}") unless type

              Column.new(name, type, true, nil)
            end
          end
          raise Error.new(21002, "Column count does not match query") unless columns.length == result.columns.length
        end
        target = Table.new(statement.name, columns, statement.keys)
        if result && statement.with_data
          result.rows.each { target.rows << target.convert_row(columns.map(&:name).zip(it).to_h) }
        end
        change(target, 0)
      end

      def insert(statement)
        target = table(statement.table).copy
        names = statement.columns || target.columns.map(&:name)
        target.validate_columns(names)
        evaluator = Evaluator.new(@parameters)
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
          row = target.columns.to_h do |column|
            expression = supplied.fetch(column.name, Default.new)
            expression = column.default if expression.is_a?(Default)
            evaluator.validate(expression)
            [column.name, expression ? evaluator.evaluate(expression) : nil]
          end
          target.rows << target.convert_row(row)
        end
        change(target, source_rows.length)
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
    end
  end
end

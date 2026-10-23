# frozen_string_literal: true

module H2
  class Connection
    DDL = [SQL::CreateTable, SQL::DropTable, SQL::Truncate].freeze

    def initialize(database, owns_database: false)
      @database = database
      @owns_database = owns_database
      @changes = {}
      @originals = {}
      @savepoints = {}
      @auto_commit = true
      @restore_auto_commit = false
      @closed = false
      @transaction_depth = 0
      @transaction_generation = 0
      @context = SessionContext.new
    end

    def execute(sql, *parameters)
      prepare(sql).execute(*parameters)
    end

    def prepare(sql)
      statement, parameter_count, generation = compile(sql)
      PreparedStatement.new(self, statement, parameter_count, sql: sql, zone_generation: generation, context: @context)
    end

    def compile(sql)
      check_open
      parser = SQL::Parser.new(sql, context: @context)
      statement = parser.parse
      statement = SQL::PrepareExpressions.new(@context, parser.parameter_count).prepare(statement)
      [statement, parser.parameter_count, @context.zone_generation]
    end

    def zone_generation
      @context.zone_generation
    end

    def execute_script(sql)
      check_open
      parser = SQL::Parser.new(sql, context: @context)
      parser.parse_script do |statement, parameter_count|
        compiled = SQL::PrepareExpressions.new(@context, parameter_count).prepare(statement)
        PreparedStatement.new(self, compiled, parameter_count, context: @context).execute
      end
    end

    def execute_prepared(statement, parameters)
      check_open
      @context.start_statement
      case statement
      when SQL::Transaction then transaction_command(statement)
      when SQL::SetTimeZone
        catalog = @database.snapshot.merge(@changes).reject { |_name, value| value.nil? }
        evaluator = SQL::Evaluator.new(parameters, queries: SQL::Queries.new(catalog, parameters, context: @context))
        evaluator.validate(statement.expression) if statement.expression
        if statement.expression && evaluator.contains_subquery?(statement.expression)
          raise Error.new(50000, "SET TIME ZONE subquery evaluation is unavailable")
        end
        @context.zone = statement.expression ? SQL::TimeZoneOperations.zone(evaluator.evaluate(statement.expression)) : TimeZone.default
        Result.new(update_count: 0)
      when SQL::SetAutocommit
        commit if statement.value && !@auto_commit
        @auto_commit = statement.value
        @restore_auto_commit = false
        Result.new(update_count: 0)
      else
        ddl = DDL.any? { statement.is_a?(it) }
        commit(ddl: true) if ddl
        @database.check_write if ddl || [SQL::Insert, SQL::Update, SQL::Delete].any? { statement.is_a?(it) }
        snapshot = @database.snapshot
        catalog = snapshot.merge(@changes).reject { |_name, value| value.nil? }
        executor = SQL::Executor.new(catalog, parameters, context: @context)
        result = executor.execute(statement)
        unless executor.changes.empty?
          if @auto_commit || ddl
            originals = executor.changes.to_h { |name, _value| [name, snapshot[name]] }
            @database.publish(executor.changes, originals)
          else
            executor.changes.each do |name, value|
              @originals[name] = snapshot[name] unless @originals.key?(name)
              @changes[name] = value
            end
          end
        end
        result
      end
    ensure
      @context.end_transaction if @auto_commit
      @context.finish_statement
    end

    def transaction
      check_open
      nested = @transaction_depth.positive? || !@auto_commit
      state = savepoint_state if nested
      saved_points = @savepoints.dup if nested
      generation = @transaction_generation
      old_auto_commit = @auto_commit
      @auto_commit = false
      @transaction_depth += 1
      finished = false
      begin
        value = yield self
        commit unless nested
        finished = true
        value
      ensure
        unless finished || closed?
          if nested && generation == @transaction_generation
            restore_savepoint(state)
            @savepoints = saved_points
          else
            rollback
          end
        end
        @transaction_depth -= 1
        @auto_commit = old_auto_commit
      end
    end

    def commit(ddl: false)
      check_open
      @context.end_transaction
      @database.publish(@changes, @originals) unless @changes.empty?
      clear_transaction
      restore_autocommit unless ddl
      nil
    end

    def rollback
      check_open
      clear_transaction
      restore_autocommit
      nil
    end

    def close
      return if @closed

      clear_transaction
      @closed = true
      @database.close if @owns_database
      nil
    end

    def closed?
      @closed || @database.closed?
    end

    private

    def check_open
      raise Error.new(90007, "Connection is closed") if closed?
    end

    def clear_transaction
      @context.end_transaction
      @transaction_generation += 1
      @changes = {}
      @originals = {}
      @savepoints.clear
    end

    def restore_autocommit
      return unless @restore_auto_commit

      @auto_commit = true
      @restore_auto_commit = false
    end

    def savepoint_state
      [@changes.dup, @originals.dup]
    end

    def restore_savepoint(state)
      @context.end_transaction
      @changes, @originals = state.map(&:dup)
    end

    def transaction_command(statement)
      case statement.operation
      when :begin
        @auto_commit = false
        @restore_auto_commit = true
      when :commit then commit
      when :rollback then rollback
      when :savepoint then @savepoints[statement.name] = savepoint_state
      when :rollback_to
        @context.end_transaction
        state = @savepoints.fetch(statement.name) { raise Error.new(90063, "Savepoint #{statement.name} not found") }
        restore_savepoint(state)
        index = @savepoints.keys.index(statement.name)
        @savepoints = @savepoints.to_a.first(index + 1).to_h
      end
      Result.new(update_count: 0)
    end
  end

  class PreparedStatement
    attr_reader :parameter_count

    def initialize(connection, statement, parameter_count, sql: nil, zone_generation: nil, context: nil)
      @connection = connection
      @statement = statement
      @parameter_count = parameter_count
      @sql = sql&.dup&.freeze
      @zone_generation = zone_generation
      @context = context
    end

    def execute(*parameters)
      if @sql && @zone_generation != @connection.zone_generation
        @statement, @parameter_count, @zone_generation = @connection.compile(@sql)
      end
      if parameters.length != parameter_count
        raise Error.new(7001, "Expected #{parameter_count} parameters, got #{parameters.length}")
      end
      values = parameters.map { copy_parameter(it) }
      @connection.execute_prepared(@statement, values)
    end

    private

    def copy_parameter(value, parents = [])
      value = Temporal.from_ruby(value)
      case value
      when String then value.dup.freeze
      when RowValue then RowValue.new(value.values.map { copy_parameter(it, parents) })
      when ArrayValue
        values = value.values.map { copy_parameter(it, parents) }
        ArrayType.new(value.element_type, values.length).convert(ArrayValue.new(values, value.element_type), cast: true, context: @context)
      when Array
        raise Error.new(22018, "Recursive array parameter") if parents.any? { it.equal?(value) }

        values = value.map { copy_parameter(it, [*parents, value]) }
        evaluator = SQL::Evaluator.new([])
        element = ArrayType.element_common(values.map { evaluator.type_of(SQL::Literal.new(it)) })
        ArrayType.new(element, values.length).convert(ArrayValue.new(values, element), cast: true, context: @context)
      when nil, true, false, Integer, BigDecimal, UUIDValue, JsonValue, DecfloatValue, DateValue, TimeValue, TimestampValue, TimeTimeZoneValue, TimestampTimeZoneValue, IntervalValue then value
      when Float
        raise Error.new(22018, "Non-finite parameter") unless value.finite?

        value
      else raise Error.new(22018, "Unsupported parameter type #{value.class}")
      end
    end
  end
end

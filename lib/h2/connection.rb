# frozen_string_literal: true

module H2
  class Connection
    DDL = [SQL::CreateTable, SQL::DropTable, SQL::Truncate].freeze

    def initialize(database)
      @database = database
      @changes = {}
      @originals = {}
      @savepoints = {}
      @auto_commit = true
      @restore_auto_commit = false
      @closed = false
      @transaction_depth = 0
      @transaction_generation = 0
    end

    def execute(sql, *parameters)
      prepare(sql).execute(*parameters)
    end

    def prepare(sql)
      check_open
      parser = SQL::Parser.new(sql)
      statement = parser.parse
      PreparedStatement.new(self, statement, parser.parameter_count)
    end

    def execute_script(sql)
      check_open
      parser = SQL::Parser.new(sql)
      parser.parse_script.map do |statement, parameter_count|
        PreparedStatement.new(self, statement, parameter_count).execute
      end
    end

    def execute_prepared(statement, parameters)
      check_open
      case statement
      when SQL::Transaction then transaction_command(statement)
      when SQL::SetAutocommit
        commit if statement.value && !@auto_commit
        @auto_commit = statement.value
        @restore_auto_commit = false
        Result.new(update_count: 0)
      else
        ddl = DDL.any? { statement.is_a?(it) }
        commit(ddl: true) if ddl
        snapshot = @database.snapshot
        catalog = snapshot.merge(@changes).reject { |_name, value| value.nil? }
        executor = SQL::Executor.new(catalog, parameters)
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
      return if closed?

      rollback
      @closed = true
      nil
    end

    def closed?
      @closed
    end

    private

    def check_open
      raise Error.new(90007, "Connection is closed") if closed?
    end

    def clear_transaction
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

    def initialize(connection, statement, parameter_count)
      @connection = connection
      @statement = statement
      @parameter_count = parameter_count
    end

    def execute(*parameters)
      if parameters.length != parameter_count
        raise Error.new(7001, "Expected #{parameter_count} parameters, got #{parameters.length}")
      end
      values = parameters.map do |value|
        case value
        when String then value.dup.freeze
        when nil, true, false, Integer, BigDecimal then value
        when Float
          raise Error.new(22018, "Non-finite parameter") unless value.finite?

          value
        else raise Error.new(22018, "Unsupported parameter type #{value.class}")
        end
      end
      @connection.execute_prepared(@statement, values)
    end
  end
end

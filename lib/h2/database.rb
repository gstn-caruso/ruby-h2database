# frozen_string_literal: true

module H2
  class Database
    def self.open(path, **options)
      database = new(path: path, **options)
      return database unless block_given?

      begin
        yield database
      ensure
        database.close
      end
    end

    def initialize(path: nil, user: "sa", password: "", read_only: false, compression: :none)
      @mutex = Mutex.new
      @closed = false
      @read_only = read_only
      if path
        require_relative "persistence/catalog"
        @storage = Persistence::Catalog.new(path, user: user, password: password, read_only: read_only, compression: compression)
      end
      @tables = @storage ? @storage.tables : {}.freeze
    end

    def connect(owns_database: false)
      check_open
      connection = Connection.new(self, owns_database: owns_database)
      return connection unless block_given?

      begin
        yield connection
      ensure
        connection.close
      end
    end

    def snapshot
      @mutex.synchronize { check_open; @tables }
    end

    def check_write
      check_open
      raise Error.new(90097, "Database is read-only") if @read_only
    end

    def closed?
      @closed || (@storage && @storage.closed?) || false
    end

    def close
      @mutex.synchronize do
        return if @closed

        begin
          @storage&.close
        ensure
          @closed = true
        end
      end
      nil
    end

    def check_open
      raise Error.new(90098, "Database is closed") if closed?
    end

    def publish(changes, originals)
      @mutex.synchronize do
        check_write
        originals.each do |name, original|
          unless @tables[name].equal?(original)
            raise Error.new(90131, "Concurrent update of table #{name}; roll back and retry")
          end
        end
        persisted = @storage ? @storage.publish(changes) : changes
        updated = @tables.merge(persisted)
        updated.delete_if { |_name, value| value.nil? }
        @tables = updated.freeze
      end
    end
  end
end

# frozen_string_literal: true

module H2
  class Database
    def initialize
      @tables = {}.freeze
      @mutex = Mutex.new
    end

    def connect
      connection = Connection.new(self)
      return connection unless block_given?

      begin
        yield connection
      ensure
        connection.close
      end
    end

    def snapshot
      @mutex.synchronize { @tables }
    end

    def publish(changes, originals)
      @mutex.synchronize do
        originals.each do |name, original|
          unless @tables[name].equal?(original)
            raise Error.new(90131, "Concurrent update of table #{name}; roll back and retry")
          end
        end
        updated = @tables.merge(changes)
        updated.delete_if { |_name, value| value.nil? }
        @tables = updated.freeze
      end
    end
  end
end

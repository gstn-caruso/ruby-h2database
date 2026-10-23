# frozen_string_literal: true

module H2
  module MVStore
    class Transaction
      attr_reader :id, :sequence, :status, :name, :log_id, :timeout_ms

      def initialize(owner, id, sequence, timeout_ms, status: :open, name: nil, log_id: 0)
        @owner, @id, @sequence, @timeout_ms = owner, id, sequence, timeout_ms
        @status, @name, @log_id = status, name, log_id
        @deadlock = false
      end

      def open_map(name, key_type: nil, value_type: nil)
        @owner.open_map(self, name, key_type: key_type, value_type: value_type)
      end

      def savepoint
        @owner.savepoint(self)
      end

      def rollback_to(savepoint)
        @owner.rollback_to(self, savepoint)
      end

      def prepare(name: nil)
        @owner.prepare(self, name)
      end

      def commit
        @owner.commit_transaction(self)
      end

      def rollback
        @owner.rollback_transaction(self)
      end

      def closed?
        status == :closed
      end

      def blocker_id
        @owner.blocker_id(self)
      end

      def advance_log
        @log_id += 1
      end

      def reset_log(value)
        @log_id = value
      end

      def transition(state, name: @name)
        @status, @name = state, name
      end

      def deadlock!
        @deadlock = true
      end

      def deadlock?
        @deadlock
      end
    end

    class TransactionMap
      include Enumerable
      attr_reader :raw_map

      def initialize(owner, transaction, map)
        @owner, @transaction, @raw_map = owner, transaction, map
      end

      def [](key)
        @owner.read(@transaction, raw_map, key)
      end

      def key?(key) = !self[key].nil?

      def []=(key, value)
        put(key, value)
        value
      end

      def put(key, value)
        raise ArgumentError, "Transaction values cannot be nil" if value.nil?

        @owner.write(@transaction, raw_map, key, value)
      end

      def delete(key)
        @owner.write(@transaction, raw_map, key, nil)
      end

      def put_if_absent(key, value)
        raise ArgumentError, "Transaction values cannot be nil" if value.nil?

        @owner.write(@transaction, raw_map, key, value, mode: :if_absent)
      end

      def lock(key, timeout_ms: nil)
        @owner.write(@transaction, raw_map, key, nil, mode: :lock, timeout_ms: timeout_ms)
      end

      def try_put(key, value)
        raise ArgumentError, "Transaction values cannot be nil" if value.nil?

        @owner.write(@transaction, raw_map, key, value, timeout_ms: 0)
        true
      rescue Error => error
        raise unless error.code == 101

        false
      end

      def each
        return enum_for(__method__) unless block_given?

        @owner.records(@transaction, raw_map).each { yield it }
        self
      end

      def size
        @owner.records(@transaction, raw_map).size
      end

      def clear
        @owner.clear_map(@transaction, raw_map)
        self
      end
    end
  end
end

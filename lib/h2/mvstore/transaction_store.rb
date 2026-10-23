# frozen_string_literal: true

require "monitor"

module H2
  module MVStore
    class TransactionStore
      LOG_BITS = 40
      LOG_MASK = (1 << LOG_BITS) - 1
      attr_reader :store

      def self.open(path, timeout_ms: 0, max_transactions: 255, **options)
        raw = Store.open(path, **options)
        transactions = new(raw, timeout_ms: timeout_ms, max_transactions: max_transactions, owns_store: true)
        return transactions unless block_given?

        begin
          yield transactions
        ensure
          transactions.close
        end
      rescue Exception
        raw&.close_immediately
        raise
      end

      def initialize(store, timeout_ms: 0, max_transactions: 255, owns_store: false, recover: true)
        raise ArgumentError, "Invalid transaction timeout" unless timeout_ms.is_a?(Integer) && timeout_ms >= 0
        raise ArgumentError, "Invalid transaction limit" unless max_transactions.is_a?(Integer) && (1..255).cover?(max_transactions)

        @store, @timeout_ms, @max_transactions, @owns_store = store, timeout_ms, max_transactions, owns_store
        @mutex = Monitor.new
        @changed = @mutex.new_cond
        @transactions, @undo_logs, @waiting = {}, {}, {}
        @sequence = 0
        @closed = false
        store.claim_transactions(self)
        @undo_type = Codecs::UndoRecordType.new(store)
        @registry = store.open_map("_", key_type: :string, value_type: :meta)
        @prepared = store.open_map("openTransactions", key_type: :object, value_type: :object)
        load_transactions
        recover! if recover && !store.read_only?
      rescue Exception
        if @store && @undo_type
          @closed = true
          @store.close_immediately
          @store.release_transactions(self)
        end
        raise
      end

      def begin_transaction(isolation: :read_committed, timeout_ms: @timeout_ms)
        raise Error.new(5, "Isolation level #{isolation} has not been ported to MVStore") unless isolation == :read_committed
        raise ArgumentError, "Invalid transaction timeout" unless timeout_ms.is_a?(Integer) && timeout_ms >= 0

        synchronize do
          check_open
          id = (1..@max_transactions).find { !@transactions.key?(it) }
          raise Error.new(102, "Too many open transactions") unless id

          @sequence += 1
          @transactions[id] = Transaction.new(self, id, @sequence, timeout_ms)
        end
      end

      def transaction(**options)
        tx = begin_transaction(**options)
        completed = false
        begin
          result = yield tx
          tx.commit
          completed = true
          result
        ensure
          tx.rollback unless completed || tx.closed? || closed?
        end
      end

      def open_map(tx, name, key_type: nil, value_type: nil)
        synchronize do
          check_transaction(tx)
          map = if store.has_map?(name)
            supplied = value_type && Codecs::VersionedType.new(Codecs.fetch(value_type))
            store.open_map(name, key_type: key_type, value_type: supplied)
          else
            check_mutable(tx)
            store.open_registered_map(name, key_type: key_type || :string,
              value_type: Codecs::VersionedType.new(Codecs.fetch(value_type || :string)))
          end
          raise Error.new(5, "Map #{name} is not a transaction map") unless map.value_type.is_a?(Codecs::VersionedType)

          TransactionMap.new(self, tx, map)
        end
      end

      def read(tx, map, key)
        synchronize { check_transaction(tx); visible_value(tx, map[key]) }
      end

      def records(tx, map)
        synchronize do
          check_transaction(tx)
          map.filter_map do |key, value|
            visible = visible_value(tx, value)
            [key, visible] unless visible.nil?
          end
        end
      end

      def write(tx, map, key, value, mode: :put, timeout_ms: nil)
        synchronize do
          check_mutable(tx)
          key = map.key_type.copy(key)
          value = map.value_type.value_type.copy(value) unless value.nil?
          timeout = timeout_ms || tx.timeout_ms
          raise ArgumentError, "Invalid lock timeout" unless timeout.is_a?(Integer) && timeout >= 0

          deadline = monotonic + timeout / 1000.0
          loop do
            check_mutable(tx)
            existing = map[key]
            blocker = existing && !existing.committed? && (existing.operation_id >> LOG_BITS)
            owner = blocker && @transactions[blocker]
            if owner && owner != tx && owner.status != :committing
              wait_for(tx, owner, deadline, timeout)
              next
            end
            if existing && !existing.committed? && owner.nil?
              existing = existing.committed.nil? ? nil : VersionedValue.new(current: existing.committed)
            end
            old = existing&.current
            return old if mode == :if_absent && !old.nil?

            operation = log_change(tx, map, key, existing)
            if mode == :lock && existing.nil?
              map.delete(key)
            else
              entry = existing && !existing.committed? && (existing.operation_id >> LOG_BITS) == tx.id ? existing.entry_id : operation & LOG_MASK
              map[key] = VersionedValue.new(current: mode == :lock ? old : value, committed: existing&.committed,
                operation_id: operation, entry_id: entry)
            end
            return old
          end
        ensure
          @waiting.delete(tx.id) if @transactions[tx.id].equal?(tx) || !@transactions.key?(tx.id)
        end
      end

      def clear_map(tx, map)
        synchronize do
          save = savepoint(tx)
          begin
            records(tx, map).each { |key, _value| write(tx, map, key, nil) }
          rescue Exception
            rollback_to(tx, save) unless tx.closed?
            raise
          end
        end
      end

      def savepoint(tx)
        synchronize { check_mutable(tx); tx.log_id }
      end

      def rollback_to(tx, savepoint)
        synchronize do
          check_mutable(tx)
          unless savepoint.is_a?(Integer) && (0..tx.log_id).cover?(savepoint)
            raise ArgumentError, "Invalid transaction savepoint"
          end
          undo_changes(tx, savepoint)
          tx.reset_log(savepoint)
          @changed.broadcast
          savepoint
        end
      end

      def prepare(tx, name)
        synchronize do
          check_mutable(tx)
          name = Codecs::STRING.copy(name) unless name.nil?
          @undo_logs[tx.id] ||= store.open_map("undoLog.#{tx.id}", key_type: :long, value_type: @undo_type)
          tx.transition(:prepared, name: name)
          @prepared[tx.id] = [2, name]
          store.commit
          tx
        rescue Error
          panic if store.closed?
          raise
        end
      end

      def commit_transaction(tx)
        synchronize do
          return if tx.closed? && !tx.deadlock?

          check_transaction(tx)
          if store.read_only? && (tx.status != :open || tx.log_id > 0)
            raise Error.new(2, "Cannot resolve persisted transaction in read-only store")
          end
          unless store.read_only?
            log = @undo_logs[tx.id]
            if log && log.size > 0
              tx.transition(:committing)
              log[(tx.id << LOG_BITS) | LOG_MASK] = UndoRecord.new(-tx.sequence, nil, nil)
              store.commit
              apply_commit(tx, log)
            end
            @prepared.delete(tx.id)
            store.commit
          end
          finish(tx)
        rescue Error
          panic if tx.status == :committing || store.closed?
          raise
        end
        nil
      end

      def rollback_transaction(tx)
        synchronize do
          return if tx.closed?

          check_transaction(tx)
          if store.read_only?
            raise Error.new(2, "Cannot resolve persisted transaction in read-only store") if tx.status != :open || tx.log_id > 0

            finish(tx)
          else
            undo_changes(tx, 0)
            @prepared.delete(tx.id)
            store.commit
            finish(tx)
          end
        rescue Error
          panic if store.closed?
          raise
        end
        nil
      end

      def in_doubt
        synchronize { check_open; @transactions.values.select { it.status == :prepared }.freeze }
      end

      def blocker_id(tx)
        synchronize { @waiting.fetch(tx.id, 0) }
      end

      def checkpoint
        synchronize do
          check_open
          store.commit
        rescue Error
          panic if store.closed?
          raise
        end
      end

      def recover!
        synchronize do
          check_open
          store.check_writable
          ordered = @transactions.values.sort_by { it.status == :committing ? [0, it.sequence] : [1, it.id] }
          ordered.each do |tx|
            if tx.status == :committing
              apply_commit(tx, @undo_logs.fetch(tx.id))
            elsif tx.status == :prepared
              next
            else
              undo_changes(tx, 0)
            end
            @prepared.delete(tx.id)
            finish(tx)
            if @undo_logs[tx.id]&.name&.start_with?("undoLog-")
              store.remove_map(@undo_logs.delete(tx.id).name)
            end
          end
          store.commit unless ordered.empty?
        end
      end

      def closed?
        @closed || store.closed?
      end

      def close
        synchronize do
          return if @closed

          begin
            store.commit unless store.closed? || store.read_only?
            store.close if @owns_store
          ensure
            @closed = true
            @changed.broadcast
            store.release_transactions(self)
          end
        end
        nil
      end

      private

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def check_open
        raise Error.new(4, "Transaction store is closed") if closed?
      end

      def check_transaction(tx)
        check_open
        raise Error.new(105, "Transaction #{tx.id} was a deadlock victim") if tx.deadlock?
        unless @transactions[tx.id].equal?(tx) && [:open, :prepared, :committing].include?(tx.status)
          raise Error.new(103, "Transaction #{tx.id} is closed")
        end
      end

      def check_mutable(tx)
        check_transaction(tx)
        store.check_writable
        raise Error.new(103, "Prepared transaction cannot be changed") unless tx.status == :open
      end

      def visible_value(tx, value)
        return nil unless value
        return value.current if value.committed? || (value.operation_id >> LOG_BITS) == tx.id

        owner = @transactions[value.operation_id >> LOG_BITS]
        owner&.status == :committing ? value.current : value.committed
      end

      def log_change(tx, map, key, existing)
        raise Error.new(104, "Transaction is too large") if tx.log_id >= LOG_MASK

        log = @undo_logs[tx.id] ||= store.open_map("undoLog.#{tx.id}", key_type: :long, value_type: @undo_type)
        operation = (tx.id << LOG_BITS) | tx.log_id
        log[operation] = UndoRecord.new(map.id, key, existing)
        tx.advance_log
        operation
      end

      def undo_changes(tx, savepoint)
        log = @undo_logs[tx.id]
        return unless log

        log.to_a.reverse_each do |operation, record|
          next if record.map_id.negative? || (operation & LOG_MASK) < savepoint

          map = store.find_map(record.map_id)
          restored = record.old_value
          if map && (restored.nil? || restored.committed? || ((restored.operation_id >> LOG_BITS) == tx.id && (restored.operation_id & LOG_MASK) < savepoint))
            restored.nil? ? map.delete(record.key) : map[record.key] = restored
          end
          log.delete(operation)
        end
      end

      def apply_commit(tx, log)
        log.to_a.each do |_operation, record|
          next if record.map_id.negative?

          map = store.find_map(record.map_id)
          next unless map

          value = map[record.key]
          next unless value && !value.committed? && (value.operation_id >> LOG_BITS) == tx.id

          value.current.nil? ? map.delete(record.key) : map[record.key] = VersionedValue.new(current: value.current)
        end
        log.clear
      end

      def finish(tx)
        tx.transition(:closed)
        @transactions.delete(tx.id)
        @waiting.delete(tx.id)
        @changed.broadcast
      end

      def load_transactions
        prepared = @prepared.to_h
        prepared.each do |id, value|
          unless id.is_a?(Integer) && (1..255).cover?(id) && value.is_a?(Array) && value.length == 2 && [1, 2, 3].include?(value[0]) && (value[1].nil? || value[1].is_a?(String))
            raise Error.new(100, "Invalid prepared transaction metadata")
          end
        end
        store.map_names.sort.each do |name|
          match = /\AundoLog([.-])(\d+)\z/.match(name)
          next unless match

          id = match[2].to_i
          raise Error.new(100, "Invalid undo log transaction id") unless (1..255).cover?(id)

          log = store.open_map(name, key_type: :long, value_type: @undo_type)
          if log.size.zero? && !prepared.key?(id)
            @undo_logs[id] ||= log if name.start_with?("undoLog.")
            next
          end
          raise Error.new(102, "Recovered transaction exceeds configured slot limit") if id > @max_transactions
          raise Error.new(100, "Duplicate transaction undo logs") if @transactions.key?(id)

          @undo_logs[id] = log
          records = log.to_a
          unless records.all? { |operation, record| (operation >> LOG_BITS) == id && ((operation & LOG_MASK) == LOG_MASK || !record.map_id.negative?) }
            raise Error.new(100, "Corrupt transaction undo log")
          end
          marker = records.last&.last
          committed = match[1] == "-" || (marker && marker.map_id.negative?) || prepared[id]&.first == 3
          state = committed ? :committing : prepared[id]&.first == 2 ? :prepared : :open
          @sequence += 1
          sequence = committed && marker&.map_id&.negative? ? -marker.map_id : @sequence
          @sequence = [@sequence, sequence].max
          log_id = records.reject { it.last.map_id.negative? }.map { (it.first & LOG_MASK) + 1 }.max || 0
          @transactions[id] = Transaction.new(self, id, sequence, @timeout_ms, status: state, name: prepared[id]&.last, log_id: log_id)
        end
      end

      def wait_for(tx, owner, deadline, timeout)
        raise Error.new(101, "Entry is locked by transaction #{owner.id}") if timeout.zero?

        @waiting[tx.id] = owner.id
        cycle = [tx]
        current = owner
        while current && !cycle.include?(current)
          cycle << current
          current = @transactions[@waiting[current.id]]
        end
        if current == tx
          victim = cycle.max_by(&:sequence)
          victim.deadlock!
          undo_changes(victim, 0)
          @prepared.delete(victim.id)
          finish(victim)
          raise Error.new(105, "Transaction #{tx.id} was a deadlock victim") if victim == tx

          return
        end
        remaining = deadline - monotonic
        raise Error.new(101, "Lock wait timed out for transaction #{tx.id}") unless remaining.positive?

        @changed.wait(remaining)
      end

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def panic
        @closed = true
        store.close_immediately
        @changed.broadcast
        store.release_transactions(self)
      end
    end
  end
end

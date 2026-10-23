# frozen_string_literal: true

module H2
  module MVStore
    class Map
      include Enumerable
      attr_reader :id, :name, :key_type, :value_type

      def initialize(store, id, name, key_type, value_type, records)
        @store, @id, @name, @key_type, @value_type = store, id, name, key_type, value_type
        load_records(records)
        @dirty = false
        @valid = true
      end

      def [](key)
        @store.synchronize do
          check_open
          key = key_type.copy(key)
          position = key_position(key)
          @records[position].last if key_found?(position, key)
        end
      end

      def key?(key)
        @store.synchronize do
          check_open
          key = key_type.copy(key)
          key_found?(key_position(key),key)
        end
      end

      def ceiling_key(key)
        @store.synchronize do
          check_open
          key = key_type.copy(key)
          @records[key_position(key)]&.first
        end
      end

      def []=(key, value)
        key, value = key_type.copy(key), value_type.copy(value)
        @store.synchronize do
          check_open
          @store.check_writable
          position = key_position(key)
          if key_found?(position, key)
            @records[position] = [@records[position].first, value]
          else
            @records.insert(position, [key, value])
          end
          @dirty = true
        end
        value
      end

      def delete(key)
        @store.synchronize do
          check_open
          @store.check_writable
          key = key_type.copy(key)
          position = key_position(key)
          return nil unless key_found?(position, key)

          @dirty = true
          @records.delete_at(position).last
        end
      end

      def size
        @store.synchronize { check_open; @records.size }
      end

      def clear
        @store.synchronize do
          check_open
          @store.check_writable
          @dirty = true unless @records.empty?
          @records.clear
        end
        self
      end

      def each
        return enum_for(__method__) { size } unless block_given?

        records = @store.synchronize { check_open; snapshot }
        records.each { yield it }
        self
      end

      def snapshot
        @records.map(&:dup)
      end

      def dirty?
        @dirty
      end

      def committed
        @dirty = false
      end

      def restore(records)
        load_records(records)
        @dirty = false
      end

      def invalidate
        @valid = false
      end

      private

      def load_records(records)
        @records = records.map(&:dup)
        unless @records.each_cons(2).all? { |left, right| key_type.compare(left.first, right.first).negative? }
          raise Error.new(6, "Map keys are not strictly ordered")
        end
      end

      def key_position(key)
        @records.bsearch_index { key_type.compare(it.first, key) >= 0 } || @records.length
      end

      def key_found?(position, key)
        position < @records.length && key_type.compare(@records[position].first, key).zero?
      end

      def check_open
        @store.check_open
        raise Error.new(4, "Map was rolled back") unless @valid
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module MVStore
    class Map
      include Enumerable
      attr_reader :id, :name, :key_type, :value_type

      def initialize(store, id, name, key_type, value_type, records)
        @store, @id, @name, @key_type, @value_type = store, id, name, key_type, value_type
        @data = records.to_h
        @dirty = false
        @valid = true
      end

      def [](key)
        @store.synchronize { check_open; @data[key_type.copy(key)] }
      end

      def []=(key, value)
        key, value = key_type.copy(key), value_type.copy(value)
        @store.synchronize do
          check_open
          @store.check_writable
          @data[key] = value
          @dirty = true
        end
        value
      end

      def delete(key)
        @store.synchronize do
          check_open
          @store.check_writable
          key = key_type.copy(key)
          @dirty = true if @data.key?(key)
          @data.delete(key)
        end
      end

      def size
        @store.synchronize { check_open; @data.size }
      end

      def each
        return enum_for(__method__) { size } unless block_given?

        records = @store.synchronize { check_open; @data.to_a }
        records.sort { key_type.compare(_1.first, _2.first) }.each { yield it }
        self
      end

      def snapshot
        @data.to_a
      end

      def dirty?
        @dirty
      end

      def committed
        @dirty = false
      end

      def restore(records)
        @data = records.to_h
        @dirty = false
      end

      def invalidate
        @valid = false
      end

      private

      def check_open
        @store.check_open
        raise Error.new(4, "Map was rolled back") unless @valid
      end
    end
  end
end

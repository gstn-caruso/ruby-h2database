# frozen_string_literal: true

module H2
  module MVStore
    UndoRecord = Data.define(:map_id, :key, :old_value)

    module Codecs
      class UndoRecordType
        include Type
        attr_reader :store

        def initialize(store)
          @store = store
          freeze
        end

        def ==(other)
          other.is_a?(UndoRecordType) && store.equal?(other.store)
        end

        def copy(record)
          raise ArgumentError, "Expected undo record" unless record.is_a?(UndoRecord)

          return record if record.map_id.negative?

          map = data_map(record.map_id)
          UndoRecord.new(record.map_id, map.key_type.copy(record.key), record.old_value.nil? ? nil : map.value_type.copy(record.old_value))
        end

        def write(buffer, record)
          DataUtils.write_var_int(buffer, record.map_id)
          return if record.map_id.negative?

          map = data_map(record.map_id)
          map.key_type.write(buffer, record.key)
          buffer.put_byte(record.old_value.nil? ? 0 : 1)
          map.value_type.write(buffer, record.old_value) unless record.old_value.nil?
        end

        def read(buffer)
          id = DataUtils.read_var_int(buffer)
          return UndoRecord.new(id, nil, nil) if id.negative?

          map = data_map(id)
          key = map.key_type.read(buffer)
          marker = buffer.byte
          raise Error.new(100, "Invalid undo record value marker") unless [0, 1].include?(marker)

          UndoRecord.new(id, key, marker == 1 ? map.value_type.read(buffer) : nil)
        end

        def compare(_left, _right)
          raise Error.new(5, "Undo records cannot be map keys")
        end

        private

        def data_map(id)
          map = @store.find_map(id)
          unless map && map.value_type.is_a?(VersionedType)
            raise Error.new(100, "Undo record references missing versioned map #{id}")
          end
          map
        end
      end
    end
  end
end

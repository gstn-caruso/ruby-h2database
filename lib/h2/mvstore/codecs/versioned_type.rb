# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class VersionedType < Data.define(:value_type)
        include Type

        def copy(value)
          raise ArgumentError, "Expected a versioned value" unless value.is_a?(VersionedValue)

          VersionedValue.new(current: value.current.nil? ? nil : value_type.copy(value.current),
            committed: value.committed.nil? ? nil : value_type.copy(value.committed), operation_id: value.operation_id, entry_id: value.entry_id)
        end

        def compare(left, right)
          value_type.compare(left.current, right.current)
        end

        def write_many(buffer, values)
          fast = values.all? { it.committed? && it.entry_id == -1 && !it.current.nil? }
          buffer.put_byte(fast ? 0 : 1)
          values.each { fast ? value_type.write(buffer, it.current) : write(buffer, it) }
        end

        def read_many(buffer, count)
          case buffer.byte
          when 0 then Array.new(count) { VersionedValue.new(current: value_type.read(buffer)) }
          when 1 then Array.new(count) { read(buffer) }
          else raise Error.new(6, "Invalid versioned value batch marker")
          end
        end

        def write(buffer, value)
          copy(value)
          if value.committed? && value.current.nil? && value.entry_id == -1
            raise ArgumentError, "Committed null reference has no versioned representation"
          end
          flags = (value.committed? ? 0 : 1) | (value.entry_id == -1 ? 0 : 2) |
            (value.current.nil? ? 0 : 4) | (value.committed? || value.committed.nil? ? 0 : 8)
          buffer.put_byte(flags)
          DataUtils.write_var_long(buffer, value.operation_id) unless value.committed?
          DataUtils.write_var_long(buffer, value.entry_id) unless value.entry_id == -1
          value_type.write(buffer, value.current) unless value.current.nil?
          value_type.write(buffer, value.committed) if !value.committed? && !value.committed.nil?
        end

        def read(buffer)
          flags = buffer.byte
          return VersionedValue.new(current: value_type.read(buffer)) if flags.zero?

          if flags >= 128
            buffer.rewind(1)
            operation = DataUtils.read_var_long(buffer)
            flags = buffer.byte
            raise Error.new(6, "Invalid legacy versioned value flags") unless (flags & ~3).zero?

            return VersionedValue.new(current: (flags & 1).zero? ? nil : value_type.read(buffer),
              committed: (flags & 2).zero? ? nil : value_type.read(buffer), operation_id: operation)
          end
          raise Error.new(6, "Invalid versioned value flags") unless (flags & ~15).zero?

          operation = (flags & 1).zero? ? 0 : DataUtils.read_var_long(buffer)
          entry = (flags & 2).zero? ? -1 : DataUtils.read_var_long(buffer)
          current = (flags & 4).zero? ? nil : value_type.read(buffer)
          committed = (flags & 8).zero? ? nil : value_type.read(buffer)
          VersionedValue.new(current: current, committed: committed, operation_id: operation, entry_id: entry)
        end
      end
    end
  end
end

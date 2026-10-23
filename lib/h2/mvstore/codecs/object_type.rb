# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class ObjectType
        include Type

        def copy(value)
          case value
          when nil, true, false then value
          when Integer
            raise ArgumentError, "Object integer requires signed 32-bit value" unless (-(1 << 31)...(1 << 31)).cover?(value)

            value
          when String then STRING.copy(value)
          when Array then value.map { copy(it) }.freeze
          else raise Error.new(5, "Java object storage type has not been ported")
          end
        end

        def compare(left, right)
          a, b = kind(left), kind(right)
          return a <=> b unless a == b

          case a
          when 0 then 0
          when 1 then (left ? 1 : 0) <=> (right ? 1 : 0)
          when 4 then left <=> right
          when 11 then STRING.compare(left, right)
          when 14
            [left.length, right.length].min.times do |index|
              result = compare(left[index], right[index])
              return result unless result.zero?
            end
            left.length <=> right.length
          end
        end

        def write(buffer, value)
          case kind(value)
          when 0 then buffer.put_byte(0)
          when 1 then buffer.put_byte(value ? 32 : 1)
          when 4
            copy(value)
            if (0..15).cover?(value)
              buffer.put_byte(64 + value)
            elsif value.abs <= 0x1f_ffff
              buffer.put_byte(value.negative? ? 33 : 4)
              DataUtils.write_var_int(buffer, value.abs)
            else
              buffer.put_byte(34).write([value].pack("l>"))
            end
          when 11
            units = STRING.units(value)
            if units.length <= 15
              buffer.put_byte(88 + units.length)
            else
              buffer.put_byte(11)
              DataUtils.write_var_int(buffer, units.length)
            end
            STRING.write_units(buffer, units)
          when 14
            buffer.put_byte(14).put_byte(8)
            DataUtils.write_var_int(buffer, value.length)
            value.each { write(buffer, it) }
          end
        end

        def read(buffer)
          tag = buffer.byte
          case tag
          when 0 then nil
          when 1 then false
          when 32 then true
          when 4 then DataUtils.read_var_int(buffer)
          when 33 then -DataUtils.read_var_int(buffer)
          when 34 then buffer.read(4).unpack1("l>")
          when 64..79 then tag - 64
          when 11 then STRING.read(buffer)
          when 88..103 then STRING.read_units(buffer, tag - 88)
          when 14
            raise Error.new(5, "Only Object[] Java array storage is implemented") unless buffer.byte == 8

            count = DataUtils.read_var_int(buffer)
            raise Error.new(6, "Invalid object array length") unless count >= 0 && count <= buffer.remaining

            Array.new(count) { read(buffer) }.freeze
          else raise Error.new(5, "Unsupported Java object storage tag #{tag}")
          end
        end

        private

        def kind(value)
          case value
          when nil then 0
          when true, false then 1
          when Integer then 4
          when String then 11
          when Array then 14
          else raise Error.new(5, "Java object storage type has not been ported")
          end
        end
      end

      OBJECT = ObjectType.new.freeze
    end
  end
end

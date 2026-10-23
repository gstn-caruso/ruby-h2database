# frozen_string_literal: true

require_relative "../../interval_units"
require_relative "../../temporal_units"

module H2
  module MVStore
    module Codecs
      class ValueType
        include Type
        TAGS = {null: 0, tinyint: 2, smallint: 3, integer: 4, bigint: 5, numeric: 6, double: 7, real: 8,
          time: 9, date: 10, timestamp: 11, varbinary: 12, varchar: 13, varchar_ignorecase: 14, blob: 15,
          clob: 16, array: 17, java_object: 19, uuid: 20, char: 21, geometry: 22, interval: 26, row: 27,
          json: 134, timestamp_tz: 135, time_tz: 136, binary: 137, decfloat: 138}.freeze
        BINARY_TAGS = [12, 19, 22, 134, 137].freeze
        NUMERIC_TYPES = [:tinyint, :smallint, :integer, :bigint, :numeric, :decfloat, :real, :double].freeze

        def copy(value)
          raise ArgumentError, "Expected H2::MVStore::Value" unless value.is_a?(Value)

          value
        end

        def compare(left, right)
          return 0 if left.equal?(right)
          return -1 if left.type == :null && right.type != :null
          return 1 if right.type == :null && left.type != :null

          if NUMERIC_TYPES.include?(left.type) && NUMERIC_TYPES.include?(right.type)
            a, b = left.to_ruby, right.to_ruby
            a_nan, b_nan = a.respond_to?(:nan?) && a.nan?, b.respond_to?(:nan?) && b.nan?
            return a_nan ? (b_nan ? 0 : 1) : -1 if a_nan || b_nan

            return a <=> b
          end
          unless left.type == right.type
            raise Error.new(5, "Comparison between #{left.type} and #{right.type} has not been ported")
          end
          case left.type
          when :null then 0
          when :varchar, :char then STRING.compare(left.data, right.data)
          when :varchar_ignorecase
            unless left.data.ascii_only? && right.data.ascii_only?
              raise Error.new(5, "Unicode case-insensitive key comparison has not been ported")
            end
            STRING.compare(left.data.upcase, right.data.upcase)
          when :boolean then (left.data ? 1 : 0) <=> (right.data ? 1 : 0)
          when :array, :row
            left.data.zip(right.data).each do |a, b|
              return -1 if b.nil?

              result = compare(a, b)
              return result unless result.zero?
            end
            right.data.length > left.data.length ? 1 : 0
          when :interval
            if IntervalUnits.year_month?(left.data[0]) != IntervalUnits.year_month?(right.data[0])
              raise Error.new(5, "Incompatible interval key families")
            end
            IntervalUnits.absolute(*left.data) <=> IntervalUnits.absolute(*right.data)
          when :time_tz
            left.data[0] - left.data[1] * 1_000_000_000 <=> right.data[0] - right.data[1] * 1_000_000_000
          when :timestamp_tz
            TemporalUnits.timestamp_zone_nanos(left.data) <=> TemporalUnits.timestamp_zone_nanos(right.data)
          when :blob, :clob
            raise Error.new(5, "Comparison of #{left.type} has not been ported")
          when :uuid then left.data <=> right.data
          else left.data <=> right.data
          end
        end

        def write(buffer, value)
          copy(value)
          type, data = value.type, value.data
          case type
          when :null then buffer.put_byte(0)
          when :boolean then buffer.put_byte(data ? 65 : 64)
          when :tinyint then buffer.put_byte(2).put_byte(data & 255)
          when :smallint then buffer.put_byte(3).write([data].pack("s>"))
          when :integer, :bigint then write_integer(buffer, data, type == :integer ? 32 : 64)
          when :numeric, :decfloat then write_decimal(buffer, type, data)
          when :real, :double then write_float(buffer, type, data)
          when :varchar
            units = STRING.units(data)
            if units.length < 32
              buffer.put_byte(68 + units.length)
              STRING.write_units(buffer, units)
            else
              buffer.put_byte(13)
              STRING.write(buffer, data)
            end
          when :char, :varchar_ignorecase
            buffer.put_byte(TAGS.fetch(type))
            STRING.write(buffer, data)
          when :varbinary
            if data.bytesize < 32
              buffer.put_byte(100 + data.bytesize).write(data)
            else
              write_bytes(buffer.put_byte(12), data)
            end
          when :uuid then buffer.put_byte(20).write(data)
          when :binary, :java_object, :geometry, :json then write_bytes(buffer.put_byte(TAGS.fetch(type)), data)
          when :array, :row
            buffer.put_byte(TAGS.fetch(type))
            DataUtils.write_var_int(buffer, data.length)
            data.each { write(buffer, it) }
          when :date
            buffer.put_byte(10)
            DataUtils.write_var_long(buffer, data)
          when :time then write_time(buffer.put_byte(9), data)
          when :timestamp, :timestamp_tz
            buffer.put_byte(TAGS.fetch(type))
            DataUtils.write_var_long(buffer, data[0])
            write_time(buffer, data[1])
            write_zone(buffer, data[2]) if type == :timestamp_tz
          when :time_tz
            buffer.put_byte(136)
            DataUtils.write_var_int(buffer, data[0] / 1_000_000_000)
            DataUtils.write_var_int(buffer, data[0] % 1_000_000_000)
            write_zone(buffer, data[1])
          when :interval
            ordinal, negative, leading, remaining = data
            raise ArgumentError, "Invalid interval qualifier" unless (0..12).cover?(ordinal)

            buffer.put_byte(26).put_byte((negative ? ~ordinal : ordinal) & 255)
            DataUtils.write_var_long(buffer, leading)
            DataUtils.write_var_long(buffer, remaining) if ordinal >= 5
          when :blob, :clob then write_lob(buffer.put_byte(TAGS.fetch(type)), type, data)
          end
        end

        def read(buffer)
          tag = buffer.byte
          type = TAGS.key(tag)
          data = case tag
          when 0 then nil
          when 2 then signed(buffer.byte, 8)
          when 3 then buffer.read(2).unpack1("s>")
          when 4 then DataUtils.read_var_int(buffer)
          when 5 then DataUtils.read_var_long(buffer)
          when 6 then read_decimal_bytes(buffer)
          when 7, 8
            width = tag == 7 ? 64 : 32
            bits = reverse_bits(DataUtils.read_variable(buffer, width), width)
            tag == 7 ? [bits].pack("Q>").unpack1("G") : [bits].pack("N").unpack1("g")
          when 9 then read_time(buffer)
          when 10 then DataUtils.read_var_long(buffer)
          when 11 then [DataUtils.read_var_long(buffer), read_time(buffer)]
          when *BINARY_TAGS then read_bytes(buffer)
          when 13, 14, 21 then STRING.read(buffer)
          when 15, 16 then read_lob(buffer, tag)
          when 17, 27
            count = DataUtils.read_var_int(buffer)
            raise Error.new(6, "Invalid SQL collection length") unless count >= 0 && count <= buffer.remaining

            Array.new(count) { read(buffer) }
          when 20 then buffer.read(16)
          when 24
            type = :timestamp_tz
            [DataUtils.read_var_long(buffer), read_time(buffer), DataUtils.read_var_int(buffer) * 60]
          when 25
            type = :integer
            DataUtils.read_var_int(buffer)
          when 26
            ordinal = signed(buffer.byte, 8)
            negative = ordinal.negative?
            ordinal = ~ordinal if negative
            raise Error.new(6, "Invalid interval qualifier") unless (0..12).cover?(ordinal)

            [ordinal, negative, DataUtils.read_var_long(buffer), ordinal >= 5 ? DataUtils.read_var_long(buffer) : 0]
          when 32..47 then type = :integer; tag - 32
          when 48..55 then type = :bigint; tag - 48
          when 56, 57 then type = :numeric; Decimal.new(tag - 56, 0)
          when 58 then type = :numeric; Decimal.new(DataUtils.read_var_long(buffer), 0)
          when 59
            type = :numeric
            scale = DataUtils.read_var_int(buffer)
            Decimal.new(DataUtils.read_var_long(buffer), scale)
          when 60, 61 then type = :double; (tag - 60).to_f
          when 62, 63 then type = :real; (tag - 62).to_f
          when 64, 65 then type = :boolean; tag == 65
          when 66 then type = :integer; signed(-DataUtils.read_var_int(buffer), 32)
          when 67 then type = :bigint; signed(-DataUtils.read_var_long(buffer), 64)
          when 68..99 then type = :varchar; STRING.read_units(buffer, tag - 68)
          when 100..131 then type = :varbinary; buffer.read(tag - 100)
          when 135 then [DataUtils.read_var_long(buffer), read_time(buffer), read_zone(buffer)]
          when 136 then [DataUtils.read_var_int(buffer) * 1_000_000_000 + DataUtils.read_var_int(buffer), read_zone(buffer)]
          when 138
            scale, length = DataUtils.read_var_int(buffer), DataUtils.read_var_int(buffer)
            if length.negative?
              {-3 => :negative_infinity, -2 => :infinity, -1 => :nan}.fetch(length) { raise Error.new(6, "Invalid DECFLOAT length") }
            else
              Decimal.new(read_big_integer(buffer, length), scale)
            end
          else raise Error.new(6, "Unknown SQL value tag #{tag}")
          end
          Value.new(type, data)
        rescue ArgumentError => error
          raise Error.new(6, "Invalid SQL value: #{error.message}")
        end

        private

        def signed(value, bits)
          value &= (1 << bits) - 1
          value >= (1 << (bits - 1)) ? value - (1 << bits) : value
        end

        def write_integer(buffer, value, bits)
          limit, compact, normal, negative = bits == 32 ? [16, 32, 4, 66] : [8, 48, 5, 67]
          if value.negative?
            buffer.put_byte(negative)
            DataUtils.write_variable(buffer, signed(-value, bits), bits)
          elsif value < limit
            buffer.put_byte(compact + value)
          else
            buffer.put_byte(normal)
            DataUtils.write_variable(buffer, value, bits)
          end
        end

        def write_decimal(buffer, type, decimal)
          if type == :decfloat
            buffer.put_byte(138)
            if decimal.is_a?(Symbol)
              DataUtils.write_var_int(buffer, 0)
              DataUtils.write_var_int(buffer, {negative_infinity: -3, infinity: -2, nan: -1}.fetch(decimal))
              return
            end
          elsif decimal.scale.zero? && [0, 1].include?(decimal.unscaled)
            buffer.put_byte(56 + decimal.unscaled)
            return
          elsif (-(1 << 63)...(1 << 63)).cover?(decimal.unscaled)
            buffer.put_byte(decimal.scale.zero? ? 58 : 59)
            DataUtils.write_var_int(buffer, decimal.scale) unless decimal.scale.zero?
            DataUtils.write_var_long(buffer, decimal.unscaled)
            return
          else
            buffer.put_byte(6)
          end
          DataUtils.write_var_int(buffer, decimal.scale)
          integer = decimal.unscaled
          length = ((integer.negative? ? ~integer : integer).bit_length + 8) / 8
          bytes = [(integer & ((1 << (length * 8)) - 1)).to_s(16).rjust(length * 2, "0")].pack("H*")
          write_bytes(buffer, bytes)
        end

        def read_decimal_bytes(buffer)
          scale = DataUtils.read_var_int(buffer)
          Decimal.new(read_big_integer(buffer, DataUtils.read_var_int(buffer)), scale)
        end

        def read_big_integer(buffer, length)
          raise Error.new(6, "Invalid big integer length") unless length.positive?

          bytes = buffer.read(length)
          signed(bytes.unpack1("H*").to_i(16), length * 8)
        end

        def reverse_bits(value, width)
          (value & ((1 << width) - 1)).to_s(2).rjust(width, "0").reverse.to_i(2)
        end

        def write_float(buffer, type, value)
          width, normal, compact = type == :double ? [64, 7, 60] : [32, 8, 62]
          if value == 0.0 || value == 1.0
            buffer.put_byte(compact + value.to_i)
          else
            bits = if value.nan?
              width == 64 ? 0x7ff8_0000_0000_0000 : 0x7fc0_0000
            else
              type == :double ? [value].pack("G").unpack1("Q>") : [value].pack("g").unpack1("N")
            end
            buffer.put_byte(normal)
            DataUtils.write_variable(buffer, signed(reverse_bits(bits, width), width), width)
          end
        end

        def write_bytes(buffer, bytes)
          DataUtils.write_var_int(buffer, bytes.bytesize)
          buffer.write(bytes)
        end

        def read_bytes(buffer)
          buffer.read(DataUtils.read_var_int(buffer))
        end

        def write_time(buffer, nanos)
          DataUtils.write_var_long(buffer, nanos / 1_000_000)
          DataUtils.write_var_int(buffer, nanos % 1_000_000)
        end

        def read_time(buffer)
          DataUtils.read_var_long(buffer) * 1_000_000 + DataUtils.read_var_int(buffer)
        end

        def write_zone(buffer, seconds)
          if seconds % 900 == 0
            buffer.put_byte((seconds / 900) & 255)
          else
            buffer.put_byte(seconds.positive? ? 127 : 128)
            DataUtils.write_var_int(buffer, seconds.abs)
          end
        end

        def read_zone(buffer)
          byte = buffer.byte
          case byte
          when 127 then DataUtils.read_var_int(buffer)
          when 128 then -DataUtils.read_var_int(buffer)
          else signed(byte, 8) * 900
          end
        end

        def write_lob(buffer, type, data)
          if data.is_a?(LobReference)
            DataUtils.write_var_int(buffer, -3)
            DataUtils.write_var_int(buffer, data.table_id)
            DataUtils.write_var_long(buffer, data.lob_id)
            DataUtils.write_var_long(buffer, data.octets)
            DataUtils.write_var_long(buffer, data.characters) if type == :clob
          elsif type == :blob
            write_bytes(buffer, data)
          else
            write_bytes(buffer, data.bytes)
            DataUtils.write_var_long(buffer, data.characters)
          end
        end

        def read_lob(buffer, tag)
          length = DataUtils.read_var_int(buffer)
          if length == -3
            LobReference.new(DataUtils.read_var_int(buffer), DataUtils.read_var_long(buffer), DataUtils.read_var_long(buffer), tag == 16 ? DataUtils.read_var_long(buffer) : nil)
          elsif length >= 0
            bytes = buffer.read(length)
            tag == 15 ? bytes : InlineClob.new(bytes, DataUtils.read_var_long(buffer))
          else
            raise Error.new(6, "Unknown LOB storage kind")
          end
        end
      end

      VALUE = ValueType.new.freeze
    end
  end
end

# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class StringType
        def units(value)
          raise ArgumentError, "Expected String" unless value.is_a?(String)
          if [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(value.encoding) && value.bytesize.odd?
            raise ArgumentError, "Incomplete UTF-16 code unit"
          end

          case value.encoding
          when Encoding::UTF_16BE then value.b.unpack("n*")
          when Encoding::UTF_16LE then value.b.unpack("v*")
          else value.encode(Encoding::UTF_16BE).unpack("n*")
          end
        end

        def copy(value)
          text = units(value).pack("n*").force_encoding(Encoding::UTF_16BE)
          (text.valid_encoding? ? text.encode(Encoding::UTF_8) : text).freeze
        end

        def compare(left, right)
          units(left) <=> units(right)
        end

        def write(buffer, value)
          characters = units(value)
          DataUtils.write_var_int(buffer, characters.length)
          characters.each do |char|
            if char < 0x80
              buffer.put_byte(char)
            elsif char >= 0x800
              buffer.put_byte(0xe0 | (char >> 12)).put_byte((char >> 6) & 0x3f).put_byte(char & 0x3f)
            else
              buffer.put_byte(0xc0 | (char >> 6)).put_byte(char & 0x3f)
            end
          end
        end

        def read(buffer)
          length = DataUtils.read_var_int(buffer)
          raise Error.new(6, "Invalid string length") unless length >= 0 && length <= buffer.remaining

          characters = Array.new(length) do
            byte = buffer.byte
            if byte < 0x80
              byte
            elsif byte >= 0xe0 && byte <= 0xef
              ((byte & 15) << 12) | (continuation(buffer) << 6) | continuation(buffer)
            elsif byte >= 0xc0 && byte < 0xe0
              ((byte & 31) << 6) | continuation(buffer)
            else
              raise Error.new(6, "Invalid UTF-16 string encoding")
            end
          end
          text = characters.pack("n*").force_encoding(Encoding::UTF_16BE)
          (text.valid_encoding? ? text.encode(Encoding::UTF_8) : text).freeze
        end

        private

        def continuation(buffer)
          byte = buffer.byte
          raise Error.new(6, "Invalid string continuation") unless byte < 64

          byte & 63
        end
      end

      class LongType
        def copy(value)
          unless value.is_a?(Integer) && (-(1 << 63)...(1 << 63)).cover?(value)
            raise ArgumentError, "Expected signed 64-bit Integer"
          end

          value
        end

        def compare(left, right)
          left <=> right
        end

        def write(buffer, value)
          DataUtils.write_var_long(buffer, copy(value))
        end

        def read(buffer)
          DataUtils.read_var_long(buffer)
        end
      end

      STRING = StringType.new.freeze
      LONG = LongType.new.freeze
      TYPES = {string: STRING, long: LONG}.freeze

      def self.fetch(name)
        return name if name == STRING || name == LONG

        TYPES.fetch(name) { raise Error.new(5, "Data type #{name.inspect} has not been ported") }
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module MVStore
    module DataUtils
      BLOCK_SIZE = 4096
      PAGE_LARGE = 2 * 1024 * 1024
      UINT64 = (1 << 64) - 1
      module_function

      def write_var_int(buffer, value)
        write_variable(buffer, value, 32)
      end

      def write_var_long(buffer, value)
        write_variable(buffer, value, 64)
      end

      def write_variable(buffer, value, bits)
        unless value.is_a?(Integer) && (-(1 << (bits - 1))...(1 << (bits - 1))).cover?(value)
          raise ArgumentError, "Integer outside signed #{bits}-bit range"
        end
        value &= (1 << bits) - 1
        while value > 127
          buffer.put_byte((value & 127) | 128)
          value >>= 7
        end
        buffer.put_byte(value)
      end

      def read_var_int(buffer)
        read_variable(buffer, 32)
      end

      def read_var_long(buffer)
        read_variable(buffer, 64)
      end

      def read_variable(buffer, bits)
        value = 0
        ((bits + 6) / 7).times do |index|
          byte = buffer.byte
          payload = byte & 127
          raise Error.new(6, "Variable integer overflow") if payload >= (1 << (bits - index * 7))

          value |= payload << (index * 7)
          if byte < 128
            return value >= (1 << (bits - 1)) ? value - (1 << bits) : value
          end
        end
        raise Error.new(6, "Unterminated variable integer")
      end

      def encode_length(length)
        raise ArgumentError, "Invalid page length" unless length.is_a?(Integer) && length >= 0

        (0...31).find { decode_length(it) >= length } || 31
      end

      def decode_length(code)
        raise ArgumentError, "Invalid length code" unless (0..31).cover?(code)

        code == 31 ? PAGE_LARGE : (2 + (code & 1)) << ((code >> 1) + 4)
      end

      def page_position(chunk, offset, length, type)
        unless (0...1 << 26).cover?(chunk) && (0...1 << 32).cover?(offset) && [0, 1].include?(type)
          raise ArgumentError, "Invalid page position fields"
        end

        (chunk << 38) | (offset << 6) | (encode_length(length) << 1) | type
      end

      def chunk_id(position)
        (position >> 38) & 0x3ff_ffff
      end

      def page_offset(position)
        (position >> 6) & 0xffff_ffff
      end

      def page_type(position)
        position & 1
      end

      def page_max_length(position)
        decode_length((position >> 1) & 31)
      end

      def check_value(value)
        ((value >> 16) ^ value) & 0xffff
      end

      def fletcher32(bytes)
        s1 = s2 = 0xffff
        index = 0
        even_length = bytes.bytesize & ~1
        while index < even_length
          stop = [index + 720, even_length].min
          while index < stop
            value = (bytes.getbyte(index) << 8) | bytes.getbyte(index + 1)
            index += 2
            s1 += value
            s2 += s1
          end
          s1 = (s1 & 0xffff) + (s1 >> 16)
          s2 = (s2 & 0xffff) + (s2 >> 16)
        end
        if bytes.bytesize.odd?
          s1 += bytes.getbyte(index) << 8
          s2 += s1
        end
        s1 = (s1 & 0xffff) + (s1 >> 16)
        s2 = (s2 & 0xffff) + (s2 >> 16)
        ((s2 << 16) | s1) & 0xffff_ffff
      end

      def dump_map(values)
        values.sort_by { |key, _value| key }.map do |key, value|
          raise ArgumentError, "Invalid metadata key" if key.include?(":") || key.include?(",")

          text = value.is_a?(Integer) ? (value & UINT64).to_s(16) : value.to_s
          text = '"' + text.gsub('"') { '\\"' } + '"' if text.include?(",") || text.include?('"')
          "#{key}:#{text}"
        end.join(",")
      end

      def parse_map(text)
        result = {}
        index = 0
        while index < text.length
          colon = text.index(":", index)
          raise Error.new(6, "Invalid metadata map") unless colon

          key = text[index...colon]
          index = colon + 1
          value = +""
          quoted = false
          while index < text.length
            char = text[index]
            index += 1
            if quoted
              if char == "\\"
                raise Error.new(6, "Invalid metadata escape") if index == text.length

                char = text[index]
                index += 1
              elsif char == '"'
                quoted = false
                next
              end
            elsif char == '"'
              quoted = true
              next
            elsif char == ","
              break
            end
            value << char
          end
          raise Error.new(6, "Unterminated metadata string") if quoted

          result[key.freeze] = value.freeze
        end
        result
      end

      def checksummed_map(values, size:)
        text = dump_map(values).encode(Encoding::ISO_8859_1).b
        text += ",fletcher:#{fletcher32(text).to_s(16)}"
        raise Error.new(3, "Metadata exceeds reserved area") if text.bytesize >= size

        (text + "\n").ljust(size, "\0")
      end

      def parse_checksummed_map(bytes)
        text = bytes.b.sub(/\A[\x00-\x20]+/, "").sub(/[\x00-\x20]+\z/, "")
        delimiter = text.rindex(",fletcher:")
        return nil unless delimiter

        raw = text.byteslice(0, delimiter)
        checksum = text.byteslice(delimiter + 10..)
        return nil unless checksum.match?(/\A[0-9a-fA-F]{1,8}\z/) && checksum.to_i(16) == fletcher32(raw)

        parse_map(raw.force_encoding(Encoding::ISO_8859_1))
      rescue Error
        nil
      end

      def hex(values, key, default = 0)
        value = values[key]
        return default if value.nil?
        raise Error.new(6, "Invalid hexadecimal #{key}") unless value.match?(/\A[0-9a-fA-F]{1,16}\z/)

        value.to_i(16)
      end
    end
  end
end

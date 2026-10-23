# frozen_string_literal: true

module H2
  module BinaryString
    INTEGER_PACK = {"TINYINT" => "c", "SMALLINT" => "s>", "INTEGER" => "l>", "BIGINT" => "q>"}.freeze
    module_function

    def binary?(value)
      value.is_a?(String) && value.encoding == Encoding::BINARY
    end

    def encode(value, source_type: nil)
      case value
      when String
        binary?(value) ? value.b : value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: "?").b
      when UUIDValue then value.bytes
      when Integer
        name = source_type&.name || (Type::INTEGER_LIMITS.fetch("INTEGER").cover?(value) ? "INTEGER" : "BIGINT")
        format = INTEGER_PACK[name]
        raise Error.new(22018, "Cannot convert #{name} to binary") unless format

        [value].pack(format)
      else raise Error.new(22018, "Cannot convert #{value.class} to binary")
      end
    end

    def text(value)
      return value.to_s unless binary?(value)

      bytes = value.bytes
      result = +""
      index = 0
      while index < bytes.length
        first = bytes[index]
        if first < 128
          result << first.chr
          index += 1
          next
        end
        width = case first
        when 0xc2..0xdf then 2
        when 0xe0..0xef then 3
        when 0xf0..0xf4 then 4
        else 1
        end
        count = 1
        while count < width && (byte = bytes[index + count]) && (0x80..0xbf).cover?(byte)
          break if count == 1 && ((first == 0xe0 && byte < 0xa0) || (first == 0xf0 && byte < 0x90) || (first == 0xf4 && byte > 0x8f))

          count += 1
        end
        point = bytes[index, count].drop(1).reduce(first & (0x7f >> width)) { |code, byte| (code << 6) | (byte & 63) }
        result << (width > 1 && count == width && !(0xd800..0xdfff).cover?(point) ? point.chr(Encoding::UTF_8) : "\uFFFD")
        index += count
      end
      result
    end
  end
end

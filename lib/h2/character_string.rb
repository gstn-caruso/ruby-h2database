# frozen_string_literal: true

module H2
  module CharacterString
    module_function

    def sql(value)
      points = sort_key(value).force_encoding(Encoding::UTF_16BE)
      points = points.valid_encoding? ? points.encode(Encoding::UTF_8).codepoints : points.unpack('n*')
      return "'#{points.pack('U*').gsub("'", "''")}'" if points.all? { (32..127).cover?(it) }

      body = points.map do |point|
        if (32...127).cover?(point)
          character = point.chr
          [39, 92].include?(point) ? character * 2 : character
        elsif point <= 0xffff then "\\#{point.to_s(16).rjust(4,'0')}"
        else "\\+#{point.to_s(16).rjust(6,'0')}"
        end
      end.join
      "U&'#{body}'"
    end

    def sort_key(value)
      case value.encoding
      when Encoding::UTF_16BE then value.b
      when Encoding::UTF_16LE then value.unpack("v*").pack("n*")
      else value.encode(Encoding::UTF_16BE).b
      end
    end

    def trim_spaces(value)
      if [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(value.encoding)
        format = value.encoding == Encoding::UTF_16BE ? "n*" : "v*"
        value.unpack(format).reverse.drop_while { it == 32 }.reverse.pack(format).force_encoding(value.encoding).freeze
      else
        value.sub(/ +\z/, "").freeze
      end
    end

    def fit(value, precision, pad:, cast:)
      return value.dup.freeze unless precision

      units = sort_key(value).unpack('n*')
      if units.length > precision
        unless cast || (pad && units.drop(precision).all? { it == 32 })
          raise Error.new(22001, "Character value exceeds declared precision")
        end
        units = units.first(precision)
      end
      units.concat(Array.new(precision - units.length, 32)) if pad
      text = units.pack('n*').force_encoding(Encoding::UTF_16BE)
      (text.valid_encoding? ? text.encode(Encoding::UTF_8) : text).freeze
    end
  end
end

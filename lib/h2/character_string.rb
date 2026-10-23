# frozen_string_literal: true

module H2
  module CharacterString
    module_function

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
  end
end

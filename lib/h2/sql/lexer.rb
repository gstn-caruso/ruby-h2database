# frozen_string_literal: true

require "strscan"
require "bigdecimal"

module H2
  module SQL
    Token = Data.define(:kind, :value, :position)

    class Lexer
      def initialize(sql)
        raise ArgumentError, "SQL must be a String" unless sql.is_a?(String)

        @scanner = StringScanner.new(source_text(sql))
      end

      def tokens
        result = []
        until @scanner.eos?
          if @scanner.skip(/\s+|--[^\n]*/)
            next
          elsif @scanner.scan(%r{/\*})
            comment
            next
          end
          position = @scanner.pos
          kind, value = scan_token
          result << Token.new(kind, value, position)
        end
        result << Token.new(:eof, nil, @scanner.pos)
        result.freeze
      end

      private

      def source_text(sql)
        return sql unless [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(sql.encoding)
        return sql.encode(Encoding::UTF_8) if sql.valid_encoding?

        units = CharacterString.sort_key(sql).unpack('n*')
        result = +''
        index = 0
        while index < units.length
          unit = units[index]
          if [34,39].include?(unit)
            quote = unit.chr
            body = []
            closed = false
            index += 1
            while index < units.length
              current = units[index]
              index += 1
              if current == unit
                unless units[index] == unit
                  closed = true
                  break
                end
                index += 1
              end
              body << current
            end
            raise Error.new(42000, "Unterminated quoted SQL text") unless closed
            text = body.pack('n*').force_encoding(Encoding::UTF_16BE)
            if text.valid_encoding?
              result << quote << text.encode(Encoding::UTF_8).gsub(quote, quote * 2) << quote
            else
              encoded = body.map do |point|
                if point == unit then quote * 2
                elsif point == 92 then '\\\\'
                elsif (32..126).cover?(point) then point.chr
                else "\\#{point.to_s(16).rjust(4,'0')}"
                end
              end.join
              result << "U&#{quote}#{encoded}#{quote}"
            end
          else
            length = (0xd800..0xdbff).cover?(unit) && (0xdc00..0xdfff).cover?(units[index + 1].to_i) ? 2 : 1
            text = units[index,length].pack('n*').force_encoding(Encoding::UTF_16BE)
            raise Error.new(42000, "Invalid SQL source encoding") unless text.valid_encoding?

            result << text.encode(Encoding::UTF_8)
            index += length
          end
        end
        result
      end

      def comment
        depth = 1
        until depth.zero?
          raise Error.new(42000, "Unterminated comment") if @scanner.eos?

          if @scanner.scan(%r{/\*})
            depth += 1
          elsif @scanner.scan(%r{\*/})
            depth -= 1
          else
            @scanner.getch
          end
        end
      end

      def scan_token
        if @scanner.scan(/[xX](?=')/)
          [:literal, binary_literal]
        elsif @scanner.scan(/[uU]&(?=['"])/)
          delimiter = @scanner.peek(1)
          raw = quoted(delimiter)
          escape = unicode_escape_character
          [delimiter == "'" ? :literal : :identifier, decode_unicode(raw, escape).freeze]
        elsif @scanner.peek(1) == "'"
          [:literal, quoted("'").freeze]
        elsif @scanner.peek(1) == '"'
          [:identifier, quoted('"').freeze]
        elsif @scanner.check(/\d|\.\d/)
          value = number
          [:literal, value]
        elsif (word = @scanner.scan(/[\p{L}_][\p{L}\p{N}_$]*/))
          [:word, word.upcase.freeze]
        elsif (symbol = @scanner.scan(/<>|!=|<=|>=|\|\||::|\?\?\(|\?\?\)|[\[\](),.;:?+*\/%=<>-]/))
          symbol = {"??(" => "[", "??)" => "]"}.fetch(symbol, symbol)
          [:symbol, symbol.freeze]
        else
          raise Error.new(42000, "Unexpected character at byte #{@scanner.pos}: #{@scanner.getch.inspect}")
        end
      end

      def binary_literal
        bytes = +"".b
        loop do
          digits = quoted("'").delete(" ")
          raise Error.new(42000, "Quote inside binary literal") if digits.include?("'")
          raise Error.new(90004, "Invalid hexadecimal string") unless digits.match?(/\A[0-9a-fA-F]*\z/)
          raise Error.new(90003, "Odd hexadecimal string length") if digits.length.odd?

          bytes << [digits].pack("H*")
          position = @scanner.pos
          skip_trivia
          unless @scanner.peek(1) == "'"
            @scanner.pos = position
            break
          end
        end
        bytes.freeze
      end

      def unicode_escape_character
        position = @scanner.pos
        skip_trivia
        unless @scanner.scan(/UESCAPE(?![\p{L}\p{N}_$])/i)
          @scanner.pos = position
          return "\\"
        end
        skip_trivia
        raise Error.new(42000, "Expected UESCAPE character") unless @scanner.peek(1) == "'"

        escape = quoted("'")
        unless escape.codepoints.length == 1 && !escape.match?(/[\s0-9A-Fa-f'"+]/)
          raise Error.new(42000, "Invalid UESCAPE character")
        end
        escape
      end

      def skip_trivia
        loop do
          if @scanner.skip(/\s+|--[^\n]*/)
            next
          elsif @scanner.scan(%r{/\*})
            comment
          else
            break
          end
        end
      end

      def decode_unicode(raw, escape)
        characters = raw.each_char.to_a
        units = []
        index = 0
        while index < characters.length
          char = characters[index]
          index += 1
          if char == escape
            char = characters[index]
            index += 1
            unless char == escape
              width = char == "+" ? 6 : 4
              digits = char == "+" ? characters[index, width]&.join : ([char] + characters[index, width - 1].to_a).join
              unless digits && digits.length == width && digits.match?(/\A[0-9a-fA-F]+\z/)
                raise Error.new(90095, "Invalid Unicode string escape")
              end
              index += char == "+" ? width : width - 1
              point = digits.to_i(16)
              raise Error.new(50000, "Invalid Unicode code point") if point > 0x10ffff

              units.concat(point > 0xffff ? [0xd800 + ((point - 0x10000) >> 10), 0xdc00 + ((point - 0x10000) & 1023)] : [point])
              next
            end
          end
          units.concat(char.encode(Encoding::UTF_16BE).unpack("n*"))
        end
        text = units.pack("n*").force_encoding(Encoding::UTF_16BE)
        text.valid_encoding? ? text.encode(Encoding::UTF_8) : text
      end

      def number
        value = if (radix = @scanner.scan(/0[xX]_?[0-9a-fA-F](?:_?[0-9a-fA-F])*|0[oO]_?[0-7](?:_?[0-7])*|0[bB]_?[01](?:_?[01])*/))
          Integer(radix.delete("_"), 0)
        else
          decimal = @scanner.scan(/(?:\d(?:_?\d)*(?:\.(?:\d(?:_?\d)*)?)?|\.\d(?:_?\d)*)(?:[Ee][+-]?\d(?:_?\d)*)?/).delete("_")
          if decimal.match?(/[Ee]/)
            begin
              DecfloatValue.parse(decimal)
            rescue Error => error
              raise unless error.code == 22018

              raise Error.new(42001, "Invalid scientific literal")
            end
          elsif decimal.include?('.')
            mantissa, exponent = decimal.split(/[Ee]/)
            scale = (mantissa.split('.', 2)[1]&.length || 0) - exponent.to_i
            digits = mantissa.delete('.').sub(/\A0+/, '')
            precision = [digits.length, 1].max + [-scale, 0].max
            DecimalLiteral.new(BigDecimal(decimal), precision, [scale, 0].max, decimal.freeze)
          else
            Integer(decimal, 10)
          end
        end
        if value.is_a?(Integer) && @scanner.scan(/[lL]/)
          raise Error.new(42001, "BIGINT literal out of range") unless Type::INTEGER_LIMITS.fetch("BIGINT").cover?(value)
          value = TypedLiteral.new(value, Type.new("BIGINT", nil, 0), Type::INTEGER_LIMITS.fetch("INTEGER").cover?(value))
        end
        if @scanner.check(/[\p{L}\p{N}_$]/) && !@scanner.check(/[kKmMgGtTpP](?![\p{L}\p{N}_$])/)
          raise Error.new(42001, "Invalid number at byte #{@scanner.pos}")
        end

        value
      end

      def quoted(delimiter)
        @scanner.getch
        value = +""
        until @scanner.eos?
          char = @scanner.getch
          if char == delimiter
            return value unless @scanner.peek(1) == delimiter

            @scanner.getch
          end
          value << char
        end
        raise Error.new(42000, "Unterminated quoted token")
      end
    end
  end
end

# frozen_string_literal: true

require "strscan"
require "bigdecimal"

module H2
  module SQL
    Token = Data.define(:kind, :value, :position)

    class Lexer
      def initialize(sql)
        raise ArgumentError, "SQL must be a String" unless sql.is_a?(String)

        @scanner = StringScanner.new(sql)
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
        if @scanner.peek(1) == "'"
          [:literal, quoted("'").freeze]
        elsif @scanner.peek(1) == '"'
          [:identifier, quoted('"').freeze]
        elsif @scanner.check(/\d|\.\d/)
          value = number
          [:literal, value]
        elsif (word = @scanner.scan(/[\p{L}_][\p{L}\p{N}_$]*/))
          [:word, word.upcase.freeze]
        elsif (symbol = @scanner.scan(/<>|!=|<=|>=|\|\||::|[(),.;?+*\/%=<>-]/))
          [:symbol, symbol.freeze]
        else
          raise Error.new(42000, "Unexpected character at byte #{@scanner.pos}: #{@scanner.getch.inspect}")
        end
      end

      def number
        value = if (radix = @scanner.scan(/0[xX]_?[0-9a-fA-F](?:_?[0-9a-fA-F])*|0[oO]_?[0-7](?:_?[0-7])*|0[bB]_?[01](?:_?[01])*/))
          Integer(radix.delete("_"), 0)
        else
          decimal = @scanner.scan(/(?:\d(?:_?\d)*(?:\.(?:\d(?:_?\d)*)?)?|\.\d(?:_?\d)*)(?:[Ee][+-]?\d(?:_?\d)*)?/).delete("_")
          decimal.match?(/[.Ee]/) ? BigDecimal(decimal) : Integer(decimal, 10)
        end
        if @scanner.check(/[\p{L}\p{N}_$]/)
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

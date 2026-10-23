# frozen_string_literal: true

require "strscan"

module H2
  module JsonDocument
    Node = Data.define(:kind, :value)
    ESCAPES = {8 => '\b', 9 => '\t', 10 => '\n', 12 => '\f', 13 => '\r', 34 => '\"', 92 => '\\\\'}.freeze
    module_function

    def number(text)
      mantissa, exponent = text.split(/[eE]/)
      scale = (mantissa.split('.', 2)[1]&.length || 0) - exponent.to_i
      raise Error.new(22018, "JSON number scale out of range") unless (-(1 << 31)...(1 << 31)).cover?(scale)

      digits = mantissa.delete('-.').sub(/\A0+/, '')
      digits = '0' if digits.empty?
      sign = mantissa.start_with?('-') && digits != '0' ? '-' : ''
      adjusted = digits.length - scale - 1
      value = if scale >= 0 && adjusted >= -6
        if scale.zero?
          digits
        elsif scale >= digits.length
          '0.' + '0' * (scale - digits.length) + digits
        else
          digits[0...-scale] + '.' + digits[-scale..]
        end
      else
        digits[0] + (digits.length > 1 ? '.' + digits[1..] : '') + 'E' + adjusted.to_s
      end
      Node.new(:number, (sign + value).freeze)
    end

    def quote(text, ascii: false)
      result = +'"'
      text.encode(Encoding::UTF_8).codepoints.each do |point|
        if (escape = ESCAPES[point])
          result << escape
        elsif point < 32 || (ascii && (point == 39 || point > 127))
          units = point > 0xffff ? [0xd800 + ((point - 0x10000) >> 10), 0xdc00 + ((point - 0x10000) & 1023)] : [point]
          units.each { result << format('\\u%04x', it) }
        else
          result << point.chr(Encoding::UTF_8)
        end
      end
      result << '"'
    rescue EncodingError
      raise Error.new(22018, "Unpaired surrogate in JSON string")
    end

    def render(node, ascii: false)
      result = +''
      pending = [node]
      until pending.empty?
        item = pending.pop
        unless item.is_a?(Node)
          result << item
          next
        end
        case item.kind
        when :array, :object
          object = item.kind == :object
          result << (object ? '{' : '[')
          pending << (object ? '}' : ']')
          item.value.reverse_each.with_index do |entry, index|
            pending << ',' if index.positive?
            if object
              pending << entry.last << ':' << quote(entry.first, ascii: ascii)
            else
              pending << entry
            end
          end
        when :string then result << quote(item.value, ascii: ascii)
        else result << item.value
        end
      end
      result
    end

    def decode(bytes)
      a, b, c, d = bytes.bytes.first(4)
      encoding = if bytes.bytesize >= 4
        case a
        when 0xfe then 'UTF-16BE' if b == 0xff
        when 0xff then c == 0 && d == 0 ? 'UTF-32LE' : 'UTF-16LE' if b == 0xfe
        when 0
          if b != 0 then 'UTF-16BE'
          elsif (c == 0 && d != 0) || (c == 0xfe && d == 0xff) then 'UTF-32BE'
          end
        else
          c == 0 && d == 0 ? 'UTF-32LE' : 'UTF-16LE' if b == 0
        end
      elsif bytes.bytesize >= 2
        a == 0 ? 'UTF-16BE' : (b == 0 ? 'UTF-16LE' : nil)
      end
      if encoding
        bytes.dup.force_encoding(encoding).encode(Encoding::UTF_8, invalid: :replace, undef: :replace)
      else
        bytes.b
      end
    end

    class Parser
      def initialize(text)
        text = BinaryString.binary?(text) ? JsonDocument.decode(text) : text.encode(Encoding::UTF_8)
        @byte_source = BinaryString.binary?(text)
        @scanner = StringScanner.new(text.delete_prefix(@byte_source ? "\xef\xbb\xbf".b : "\uFEFF"))
        @frames = []
      rescue EncodingError
        raise Error.new(22018, "Invalid JSON text encoding")
      end

      def parse
        root = value
        until @frames.empty?
          node, state = @frames.last
          skip
          closing = node.kind == :object ? '}' : ']'
          if state != :next && @scanner.scan(Regexp.new(Regexp.escape(closing)))
            node.value.freeze
            @frames.pop
          elsif state == :after
            expect(',')
            @frames.last[1] = :next
          else
            @frames.last[1] = :after
            if node.kind == :object
              expect('"')
              key = string
              expect(':')
              node.value << [key, value].freeze
            else
              node.value << value
            end
          end
        end
        skip
        invalid unless @scanner.eos?
        root
      end

      private

      def value
        skip
        if (opening = @scanner.scan(/[\[{]/))
          node = Node.new(opening == '{' ? :object : :array, [])
          @frames << [node, :first]
          node
        elsif @scanner.scan(/"/)
          Node.new(:string, string)
        elsif (literal = @scanner.scan(/true|false|null/))
          Node.new(:literal, literal.freeze)
        elsif (text = @scanner.scan(/-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?/))
          JsonDocument.number(text)
        else
          invalid
        end
      end

      def string
        result = +''
        high = nil
        loop do
          char = @scanner.getch
          invalid unless char
          if char == '"'
            invalid if high
            return result.freeze
          end
          if char == '\\'
            char = @scanner.getch
            invalid unless char
            if char == 'u'
              point = hex
            else
              char = {'"' => '"', '/' => '/', '\\' => '\\', 'b' => "\b", 'f' => "\f", 'n' => "\n", 'r' => "\r", 't' => "\t"}[char]
              invalid unless char
              point = char.ord
            end
          else
            point = codepoint(char)
          end
          if high
            invalid unless (0xdc00..0xdfff).cover?(point)
            result << (0x10000 + ((high - 0xd800) << 10) + point - 0xdc00).chr(Encoding::UTF_8)
            high = nil
          elsif (0xd800..0xdbff).cover?(point)
            high = point
          else
            invalid if (0xdc00..0xdfff).cover?(point)
            result << point.chr(Encoding::UTF_8)
          end
        end
      end

      def codepoint(char)
        point = char.ord
        return point unless @byte_source && point >= 0x80

        width, mask, minimum = if point >= 0xf0 then [4, 15, 0x10000]
        elsif point >= 0xe0 then [3, 15, 0x800]
        else [2, 31, 0x80]
        end
        point &= mask
        (width - 1).times do
          byte = @scanner.getch&.ord
          invalid unless byte && (byte & 0xc0) == 0x80
          point = (point << 6) | (byte & 63)
        end
        invalid unless point >= minimum && point <= 0x10ffff
        point
      end

      def hex
        digits = Array.new(4) { @scanner.getch }
        invalid if digits.any?(&:nil?)
        sign = digits.first == '-' ? -1 : 1
        digits.shift if %w[+ -].include?(digits.first)
        value = digits.reduce(0) do |result, char|
          point = char.ord
          digit = if (48..57).cover?(point) then point - 48
          elsif (65..70).cover?(point) then point - 55
          elsif (97..102).cover?(point) then point - 87
          elsif !@byte_source && (0xff21..0xff26).cover?(point) then point - 0xff17
          elsif !@byte_source && (0xff41..0xff46).cover?(point) then point - 0xff37
          elsif !@byte_source && point <= 0xffff && char.match?(/\p{Nd}/)
            first = point
            first -= 1 while (first - 1).chr(Encoding::UTF_8).match?(/\p{Nd}/)
            (point - first) % 10
          end
          invalid unless digit
          result * 16 + digit
        end
        (value * sign) & 0xffff
      end

      def skip
        @scanner.skip(/[ \t\r\n]*/)
      end

      def expect(text)
        skip
        invalid unless @scanner.scan(Regexp.new(Regexp.escape(text)))
      end

      def invalid
        raise Error.new(22018, "Invalid JSON at byte #{@scanner.pos}")
      end
    end
  end
end

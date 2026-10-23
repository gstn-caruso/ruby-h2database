# frozen_string_literal: true

require "zlib"

module H2
  module MVStore
    module Compression
      module_function

      def compress(bytes, level)
        case level
        when :none then [bytes, 0]
        when :fast then [lzf_compress(bytes), 2]
        when :high then [Zlib::Deflate.deflate(bytes), 6]
        else raise ArgumentError, "Unknown compression #{level.inspect}"
        end
      end

      def expand(bytes, expected, flags)
        raise Error.new(6, "Invalid expanded page length") unless (0...1 << 31).cover?(expected)

        output = (flags & 6) == 6 ? Zlib::Inflate.inflate(bytes) : lzf_expand(bytes, expected)
        raise Error.new(6, "Expanded page length mismatch") unless output.bytesize == expected

        output
      rescue Zlib::Error => error
        raise Error.new(6, "Invalid compressed page: #{error.message}")
      end

      def lzf_expand(bytes, expected)
        input = Buffer.new(bytes)
        output = +"".b
        until output.bytesize >= expected
          control = input.byte
          if control < 32
            length = control + 1
            raise Error.new(6, "LZF literal exceeds page") if output.bytesize + length > expected

            output << input.read(length)
          else
            length = control >> 5
            length += input.byte if length == 7
            length += 2
            distance = ((control & 31) << 8) + input.byte + 1
            start = output.bytesize - distance
            raise Error.new(6, "Invalid LZF back reference") if start.negative? || output.bytesize + length > expected

            pattern = output.byteslice(start, [distance, length].min)
            output << (pattern * ((length + pattern.bytesize - 1) / pattern.bytesize)).byteslice(0, length)
          end
        end
        raise Error.new(6, "Trailing LZF data") unless input.remaining.zero?

        output
      end

      def lzf_compress(bytes)
        output = +"".b
        literals = +"".b
        positions = {}
        index = 0
        flush = lambda do
          unless literals.empty?
            output << (literals.bytesize - 1).chr << literals
            literals.clear
          end
        end
        while index < bytes.bytesize
          reference = nil
          if index + 3 < bytes.bytesize
            key = (bytes.getbyte(index) << 16) | (bytes.getbyte(index + 1) << 8) | bytes.getbyte(index + 2)
            reference = positions[key]
            positions[key] = index
          end
          if reference && index - reference <= 8192
            length = 3
            maximum = [264, bytes.bytesize - index - 1].min
            length += 1 while length < maximum && bytes.getbyte(reference + length) == bytes.getbyte(index + length)
            flush.call
            distance = index - reference - 1
            encoded_length = length - 2
            output << (([encoded_length, 7].min << 5) | (distance >> 8)).chr
            output << (encoded_length - 7).chr if encoded_length >= 7
            output << (distance & 255).chr
            (index + 1...index + length).each do |position|
              if position + 2 < bytes.bytesize
                key = (bytes.getbyte(position) << 16) | (bytes.getbyte(position + 1) << 8) | bytes.getbyte(position + 2)
                positions[key] = position
              end
            end
            index += length
          else
            literals << bytes.getbyte(index).chr
            index += 1
            flush.call if literals.bytesize == 32
          end
        end
        flush.call
        output
      end
    end
  end
end

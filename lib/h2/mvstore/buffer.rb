# frozen_string_literal: true

module H2
  module MVStore
    class Buffer
      attr_reader :data, :offset

      def initialize(data = "".b)
        @data = data.b.dup
        @offset = 0
      end

      def remaining
        data.bytesize - offset
      end

      def rewind(length)
        raise Error.new(6, "Invalid buffer rewind") unless length >= 0 && length <= offset

        @offset -= length
      end

      def read(length)
        raise Error.new(6, "Truncated binary value") unless length >= 0 && length <= remaining

        value = data.byteslice(offset, length)
        @offset += length
        value
      end

      def byte
        raise Error.new(6, "Truncated binary value") if remaining.zero?

        value = data.getbyte(offset)
        @offset += 1
        value
      end

      def uint16
        read(2).unpack1("n")
      end

      def uint32
        read(4).unpack1("N")
      end

      def uint64
        read(8).unpack1("Q>")
      end

      def write(bytes)
        @data << bytes.b
        self
      end

      def put_byte(value)
        @data << value.chr(Encoding::BINARY)
        self
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module MVStore
    class Page < Data.define(:keys, :values, :children, :counts, :number, :flags)
      def leaf?
        (flags & 1).zero?
      end

      def count
        leaf? ? keys.length : counts.sum
      end

      def self.decode(bytes, position, map_id, key_type, value_type)
        buffer = Buffer.new(bytes)
        length = buffer.uint32
        raise Error.new(6, "Invalid page length") unless length == bytes.bytesize && length >= 10

        checksum = DataUtils.check_value(DataUtils.chunk_id(position)) ^ DataUtils.check_value(DataUtils.page_offset(position)) ^ DataUtils.check_value(length)
        raise Error.new(6, "Page position checksum mismatch") unless buffer.uint16 == checksum

        number = DataUtils.read_var_int(buffer)
        raise Error.new(6, "Negative page number") if number.negative?
        raise Error.new(6, "Page map id mismatch") unless DataUtils.read_var_int(buffer) == map_id

        count = DataUtils.read_var_int(buffer)
        flags = buffer.byte
        raise Error.new(6, "Page node type mismatch") unless (flags & 1) == DataUtils.page_type(position)
        raise Error.new(5, "Unknown page flags #{flags}") unless (flags & ~7).zero?
        raise Error.new(6, "Invalid page key count") unless count >= 0 && count <= buffer.remaining

        children = []
        counts = []
        if (flags & 1) == 1
          children = Array.new(count + 1) { buffer.uint64 }
          counts = Array.new(count + 1) { DataUtils.read_var_long(buffer) }
          raise Error.new(6, "Negative descendant count") if counts.any?(&:negative?)
        end
        if (flags & 2) != 0
          addition = DataUtils.read_var_int(buffer)
          raise Error.new(6, "Invalid compressed page length") if addition.negative?

          compressed = buffer.read(buffer.remaining)
          buffer = Buffer.new(Compression.expand(compressed, compressed.bytesize + addition, flags))
        end
        keys = Array.new(count) { key_type.read(buffer) }
        unless keys.each_cons(2).all? { key_type.compare(_1, _2).negative? }
          raise Error.new(6, "Page keys are not strictly ordered")
        end
        values = (flags & 1).zero? ? Array.new(count) { value_type.read(buffer) } : []
        raise Error.new(6, "Trailing page payload") unless buffer.remaining.zero?

        new(keys.freeze, values.freeze, children.freeze, counts.freeze, number, flags)
      end

      def self.encode(keys:, values:, children:, counts:, number:, map_id:, chunk_id:, offset:, key_type:, value_type:, compression:)
        type = children.empty? ? 0 : 1
        payload = Buffer.new
        keys.each { key_type.write(payload, it) }
        values.each { value_type.write(payload, it) } if type.zero?
        bytes = payload.data
        compressed, flags = Compression.compress(bytes, compression)
        if flags != 0 && compressed.bytesize < bytes.bytesize
          delta = Buffer.new
          DataUtils.write_var_int(delta, bytes.bytesize - compressed.bytesize)
          if delta.data.bytesize + compressed.bytesize < bytes.bytesize
            bytes = delta.data + compressed
            type |= flags
          end
        end
        body = Buffer.new
        DataUtils.write_var_int(body, number)
        DataUtils.write_var_int(body, map_id)
        DataUtils.write_var_int(body, keys.length)
        body.put_byte(type)
        children.each { body.write([it].pack("Q>")) }
        counts.each { DataUtils.write_var_long(body, it) }
        body.write(bytes)
        length = body.data.bytesize + 6
        checksum = DataUtils.check_value(chunk_id) ^ DataUtils.check_value(offset) ^ DataUtils.check_value(length)
        [length, checksum].pack("Nn") + body.data
      end
    end
  end
end

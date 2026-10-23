# frozen_string_literal: true

module H2
  module MVStore
    class ChunkWriter
      Reference = Data.define(:position, :count, :first_key)
      attr_reader :id, :version

      def initialize(id:, version:, block:, map_id:, time:, keys_per_page:, compression:)
        @id, @version, @block, @map_id, @time = id, version, block, map_id, time
        @keys_per_page, @compression = keys_per_page, compression
        @bytes = "\0".b * 256
        @toc = []
        @max_length = 0
      end

      def write_map(map_id, records, key_type, value_type)
        return 0 if records.empty?

        records = records.sort { key_type.compare(_1.first, _2.first) }
        level = records.each_slice(@keys_per_page).map do |group|
          position = add_page(map_id, group.map(&:first), group.map(&:last), [], [], key_type, value_type)
          Reference.new(position, group.length, group.first.first)
        end
        while level.length > 1
          level = level.each_slice(@keys_per_page + 1).map do |children|
            keys = children.drop(1).map(&:first_key)
            position = add_page(map_id, keys, [], children.map(&:position), children.map(&:count), key_type, value_type)
            Reference.new(position, children.sum(&:count), children.first.first_key)
          end
        end
        level.first.position
      end

      def finish(layout)
        root = write_map(0, layout.to_a, Codecs::STRING, Codecs::STRING)
        toc_position = @bytes.bytesize
        @bytes << @toc.pack("Q>*")
        blocks = (@bytes.bytesize + 128 + 4095) / 4096
        @bytes = @bytes.ljust(blocks * 4096, "\0")
        header = "chunk:#{id.to_s(16)},len:#{blocks.to_s(16)},pages:#{@toc.length.to_s(16)},max:#{@max_length.to_s(16)},map:#{@map_id.to_s(16)},root:#{root.to_s(16)},time:#{@time.to_s(16)},version:#{version.to_s(16)},toc:#{toc_position.to_s(16)}"
        raise Error.new(3, "Chunk header exceeds reserved space") if header.bytesize > 255

        @bytes[0, 256] = header.ljust(255, " ") + "\n"
        @bytes[-128, 128] = Chunk.footer(id, blocks, version)
        @bytes
      end

      private

      def add_page(map_id, keys, values, children, counts, key_type, value_type)
        offset = @bytes.bytesize
        bytes = Page.encode(keys: keys, values: values, children: children, counts: counts, number: @toc.length,
          map_id: map_id, chunk_id: id, offset: offset, key_type: key_type, value_type: value_type, compression: @compression)
        type = children.empty? ? 0 : 1
        position = DataUtils.page_position(id, offset, bytes.bytesize, type)
        @toc << DataUtils.page_position(map_id, offset, bytes.bytesize, type)
        @max_length += DataUtils.page_max_length(position)
        @bytes << bytes
        position
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module MVStore
    class Reader
      attr_reader :header, :chunks, :layout, :metadata, :version, :last_chunk

      def initialize(storage)
        @storage = storage
        @pages = {}
        raise Error.new(5, "Encrypted MVStore files have not been ported") if storage.read_at(0, [10, storage.size].min).start_with?("H2encrypt")
        raise Error.new(6, "Truncated MVStore header") if storage.size < 8192

        headers = [0, 4096].filter_map { DataUtils.parse_checksummed_map(storage.read_at(it, 4096)) }
        raise Error.new(6, "Both MVStore headers are corrupt") if headers.empty?

        @header = headers.max_by { DataUtils.hex(it, "version") }.freeze
        format = DataUtils.hex(header, "formatRead", DataUtils.hex(header, "format", 1))
        unless format == 3 && DataUtils.hex(header, "blockSize", 4096) == 4096
          raise Error.new(5, "Unsupported MVStore format #{format}")
        end
        @chunks = scan_chunks
        if chunks.empty?
          raise Error.new(6, "Header references a missing chunk") unless DataUtils.hex(header, "chunk").zero?

          @version = 0
          @layout = {"meta.id" => "1"}.freeze
          @metadata = {}.freeze
          return
        end
        clean = headers.length == 2 && headers.all? { DataUtils.hex(it, "clean") == 1 && DataUtils.hex(it, "version") == DataUtils.hex(header, "version") }
        selected = chunks[DataUtils.hex(header, "chunk")]
        candidates = chunks.values.sort_by { [-it.version, it.block] }
        candidates = [selected] if clean && selected && selected.version == DataUtils.hex(header, "version")
        failure = nil
        candidates.each do |chunk|
          begin
            @layout = records(chunk.root, 0, Codecs::STRING, Codecs::STRING).to_h.freeze
            meta_id = DataUtils.hex(layout, "meta.id", 1)
            @metadata = records(DataUtils.hex(layout, "root.#{meta_id.to_s(16)}"), meta_id, Codecs::STRING, Codecs::STRING).to_h.freeze
            layout.each do |key, value|
              if key.start_with?("root.") && !value.to_i(16).zero? && !chunks.key?(DataUtils.chunk_id(value.to_i(16)))
                raise Error.new(9, "Map root references a missing chunk")
              end
            end
            @version, @last_chunk = chunk.version, chunk
            return
          rescue Error => error
            failure = error
          end
        end
        raise failure || Error.new(6, "No recoverable MVStore chunk")
      end

      def records(position, map_id, key_type, value_type)
        return enum_for(__method__, position, map_id, key_type, value_type) unless block_given?
        return if position.zero?

        visited = {}
        walk = lambda do |current, expected_count|
          return if current.zero? && expected_count == 0
          raise Error.new(6, "Cyclic or missing page reference") if current.zero? || visited[current]

          visited[current] = true
          page = read_page(current, map_id, key_type, value_type)
          if expected_count && page.count != expected_count
            raise Error.new(6, "B-tree descendant count mismatch")
          end
          if page.leaf?
            page.keys.each_with_index { |key, index| yield [key, page.values[index]] }
          else
            page.children.each_with_index { |child, index| walk.call(child, page.counts[index]) }
          end
        end
        walk.call(position, nil)
      end

      def read_page(position, map_id, key_type, value_type)
        @pages.fetch([position, map_id, key_type, value_type]) do |key|
          chunk = chunks.fetch(DataUtils.chunk_id(position)) { raise Error.new(9, "Chunk #{DataUtils.chunk_id(position)} not found") }
          offset = DataUtils.page_offset(position)
          start = chunk.block * 4096 + offset
          length = @storage.read_at(start, 4).unpack1("N")
          if offset < 1 || length < 10 || offset + length > chunk.length * 4096 - 128
            raise Error.new(6, "Page exceeds chunk boundaries")
          end
          if DataUtils.page_max_length(position) != DataUtils::PAGE_LARGE && length > DataUtils.page_max_length(position)
            raise Error.new(6, "Page exceeds encoded length")
          end
          @pages[key] = Page.decode(@storage.read_at(start, length), position, map_id, key_type, value_type)
        end
      end

      private

      def scan_chunks
        result = {}
        block = 2
        blocks = @storage.size / 4096
        while block < blocks
          begin
            bytes = @storage.read_at(block * 4096, [1024, @storage.size - block * 4096].min)
            terminator = bytes.index("\n")
            raise Error.new(6, "Missing chunk header") unless terminator && bytes.start_with?("chunk:")

            chunk = Chunk.new(DataUtils.parse_map(bytes.byteslice(0, terminator).strip), block)
            raise Error.new(6, "Incomplete chunk") if block + chunk.length > blocks

            footer = @storage.read_at((block + chunk.length) * 4096 - 128, 128)
            raise Error.new(6, "Chunk footer checksum mismatch") unless chunk.footer_valid?(footer)

            previous = result[chunk.id]
            result[chunk.id] = chunk if !previous || chunk.version > previous.version || (chunk.version == previous.version && chunk.block < previous.block)
            block += chunk.length
          rescue Error
            block += 1
          end
        end
        result.freeze
      end
    end
  end
end

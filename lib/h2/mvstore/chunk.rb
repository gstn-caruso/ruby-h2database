# frozen_string_literal: true

module H2
  module MVStore
    class Chunk
      attr_reader :attributes, :block, :id, :length, :version, :root

      def initialize(attributes, block)
        @attributes = attributes.freeze
        @block = block
        @id = DataUtils.hex(attributes, "chunk", -1)
        @length = DataUtils.hex(attributes, "len")
        @version = DataUtils.hex(attributes, "version", id)
        @root = DataUtils.hex(attributes, "root")
        unless (0...1 << 26).cover?(id) && length.positive? && block >= 2
          raise Error.new(6, "Invalid chunk descriptor")
        end
      end

      def metadata
        DataUtils.dump_map(attributes.merge("block" => block))
      end

      def footer_valid?(bytes)
        values = DataUtils.parse_checksummed_map(bytes)
        values && DataUtils.hex(values, "chunk", -1) == id && DataUtils.hex(values, "len") == length && DataUtils.hex(values, "version") == version
      end

      def self.footer(id, length, version)
        text = "chunk:#{id.to_s(16)},len:#{length.to_s(16)},version:#{version.to_s(16)}"
        (text + ",fletcher:#{DataUtils.fletcher32(text).to_s(16)}").ljust(127, " ") + "\n"
      end
    end
  end
end

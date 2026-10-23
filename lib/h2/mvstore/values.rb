# frozen_string_literal: true

require "bigdecimal"

module H2
  module MVStore
    BlobMetadata = Data.define(:stream_id, :table_id, :byte_count, :content_hash) do
      def initialize(stream_id:, table_id:, byte_count:, content_hash:)
        raise ArgumentError, "Expected stream identifier bytes" unless stream_id.is_a?(String)
        unless table_id.is_a?(Integer) && (-(1 << 31)...(1 << 31)).cover?(table_id)
          raise ArgumentError, "Invalid LOB table id"
        end
        Codecs::LONG.copy(byte_count)
        Codecs::LONG.copy(content_hash)
        super(stream_id: stream_id.b.freeze, table_id: table_id, byte_count: byte_count, content_hash: content_hash)
      end
    end

    BlobReference = Data.define(:stream_id, :lob_id) do
      def initialize(stream_id:, lob_id:)
        raise ArgumentError, "Expected stream identifier bytes" unless stream_id.is_a?(String)
        Codecs::LONG.copy(lob_id)
        super(stream_id: stream_id.b.freeze, lob_id: lob_id)
      end
    end

    Decimal = Data.define(:unscaled, :scale) do
      def initialize(unscaled:, scale:)
        raise ArgumentError, "Expected decimal integer and signed 32-bit scale" unless unscaled.is_a?(Integer) && scale.is_a?(Integer) && (-(1 << 31)...(1 << 31)).cover?(scale)

        super
      end

      def to_d
        BigDecimal("#{unscaled}e#{-scale}")
      end
    end

    LobReference = Data.define(:table_id, :lob_id, :octets, :characters) do
      def initialize(table_id:, lob_id:, octets:, characters:)
        unless table_id.is_a?(Integer) && (-(1 << 31)...(1 << 31)).cover?(table_id)
          raise ArgumentError, "Invalid LOB table id"
        end
        [lob_id, octets, characters].compact.each { Codecs::LONG.copy(it) }
        raise ArgumentError, "Invalid LOB lengths" if octets.negative? || (characters && characters.negative?)

        super
      end
    end
    InlineClob = Data.define(:bytes, :characters) do
      def initialize(bytes:, characters:)
        raise ArgumentError, "Expected CLOB bytes" unless bytes.is_a?(String)
        Codecs::LONG.copy(characters)
        raise ArgumentError, "Negative CLOB character count" if characters.negative?

        super(bytes: bytes.b.freeze, characters: characters)
      end
    end

    class Value < Data.define(:type, :data)
      INTEGERS = {tinyint: 8, smallint: 16, integer: 32, bigint: 64, enum: 32, date: 64, time: 64}.freeze
      STRINGS = [:varchar, :char, :varchar_ignorecase].freeze
      BINARY = [:varbinary, :binary, :java_object, :geometry, :json, :uuid].freeze
      TYPES = (INTEGERS.keys + STRINGS + BINARY + [:null, :boolean, :numeric, :decfloat, :real, :double,
        :time_tz, :timestamp, :timestamp_tz, :interval, :array, :row, :blob, :clob]).freeze

      def initialize(type:, data:)
        raise ArgumentError, "Unknown SQL storage type #{type}" unless TYPES.include?(type)

        copied = if (bits = INTEGERS[type])
          raise ArgumentError, "Integer outside #{type} range" unless data.is_a?(Integer) && (-(1 << (bits - 1))...(1 << (bits - 1))).cover?(data)

          data
        elsif STRINGS.include?(type)
          Codecs::STRING.copy(data)
        elsif BINARY.include?(type) || (type == :blob && data.is_a?(String))
          raise ArgumentError, "Expected binary String" unless data.is_a?(String)
          raise ArgumentError, "UUID requires 16 bytes" if type == :uuid && data.bytesize != 16

          data.b.freeze
        else
          copy_data(type, data)
        end
        super(type: type, data: copied)
      end

      def to_ruby
        case type
        when :numeric then data.to_d
        when :decfloat then data.is_a?(Decimal) ? data.to_d : BigDecimal({infinity: "Infinity", negative_infinity: "-Infinity", nan: "NaN"}.fetch(data))
        when :array, :row then data.map(&:to_ruby).freeze
        else data
        end
      end

      private

      def copy_data(type, data)
        valid = case type
        when :null then data.nil?
        when :boolean then data == true || data == false
        when :numeric then data.is_a?(Decimal) && (0..100_000).cover?(data.scale)
        when :decfloat then data.is_a?(Decimal) || [:infinity, :negative_infinity, :nan].include?(data)
        when :real, :double then data.is_a?(Float)
        when :array, :row then data.is_a?(Array) && data.all? { it.is_a?(Value) }
        when :time_tz, :timestamp, :timestamp_tz, :interval
          width = {time_tz: 2, timestamp: 2, timestamp_tz: 3, interval: 4}.fetch(type)
          data.is_a?(Array) && data.length == width && data.each_with_index.all? { |value, index| type == :interval && index == 1 ? [true, false].include?(value) : value.is_a?(Integer) }
        when :blob then data.is_a?(LobReference) && data.characters.nil?
        when :clob then data.is_a?(InlineClob) || data.is_a?(LobReference)
        end
        raise ArgumentError, "Invalid #{type} storage value" unless valid
        if [:time_tz, :timestamp_tz].include?(type) && !(-64_800..64_800).cover?(data.last)
          raise ArgumentError, "Invalid time zone offset"
        end
        if type == :interval && (!(0..12).cover?(data[0]) || data[2].negative? || data[3].negative? || (data[0] < 5 && data[3] != 0))
          raise ArgumentError, "Invalid interval components"
        end

        return data.dup.freeze if data.is_a?(Array)
        return 0.0 if [:real, :double].include?(type) && data.zero?
        return [data].pack("g").unpack1("g") if type == :real

        data
      end
    end

    SearchRow = Data.define(:key, :values) do
      def initialize(key:, values:)
        Codecs::LONG.copy(key)
        raise ArgumentError, "Expected SQL values or missing index columns" unless values.is_a?(Array) && values.all? { it.nil? || it.is_a?(Value) }

        super(key: key, values: values.dup.freeze)
      end
    end

    VersionedValue = Data.define(:current, :committed, :operation_id, :entry_id) do
      def initialize(current:, committed: nil, operation_id: 0, entry_id: -1)
        Codecs::LONG.copy(operation_id)
        Codecs::LONG.copy(entry_id)
        super(current: current, committed: operation_id.zero? ? current : committed, operation_id: operation_id, entry_id: entry_id)
      end

      def committed?
        operation_id.zero?
      end
    end
  end
end

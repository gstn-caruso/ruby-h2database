# frozen_string_literal: true

module H2
  class EnumValue < Data.define(:type, :index, :zero_based)
    def initialize(type:, index:, zero_based: false)
      unless type.is_a?(EnumType) && index.is_a?(Integer) && (0...type.labels.length).cover?(index) && [true,false].include?(zero_based)
        raise Error.new(22030, "Invalid ENUM value")
      end
      super
    end

    def label = type.labels.fetch(index)
    def ordinal = index + (zero_based ? 0 : 1)
    def to_s = label
    def to_i = ordinal
  end

  class EnumType < Data.define(:labels, :keys)
    def initialize(labels:, keys: nil)
      raise Error.new(22032, "Empty ENUM declaration") if labels.empty?
      raise Error.new(22001, "Too many ENUM labels") if labels.length > 65_536

      labels = labels.map { it&.dup&.freeze }.freeze
      cleaned = labels.map { self.class.clean(it) }
      raise Error.new(22032, "Empty ENUM label") if cleaned.any? { it.nil? || it.empty? }
      raise Error.new(22033, "Duplicate ENUM label") if cleaned.uniq.length != cleaned.length

      super(labels: labels, keys: cleaned.each_with_index.to_h.freeze)
    end

    def self.clean(label)
      return nil if label.nil?

      units = CharacterString.sort_key(label).unpack('n*')
      units = units.drop_while { it <= 32 }.reverse.drop_while { it <= 32 }.reverse
      result = +''.b
      index = 0
      while index < units.length
        point = units[index]
        if (0xd800..0xdbff).cover?(point) && (0xdc00..0xdfff).cover?(units[index + 1].to_i)
          point = 0x10000 + ((point - 0xd800) << 10) + units[index + 1] - 0xdc00
          index += 1
        elsif (0xd800..0xdfff).cover?(point)
          result << [point].pack('n')
          index += 1
          next
        end
        result << point.chr(Encoding::UTF_8).upcase.encode(Encoding::UTF_16BE).b
        index += 1
      end
      result.freeze
    end

    def name = "ENUM"
    def type_name
      units = 'ENUM('.encode(Encoding::UTF_16BE).unpack('n*')
      labels.each_with_index do |label, index|
        units.concat([44,32]) if index.positive?
        units << 39
        CharacterString.sort_key(label).unpack('n*').each { |unit| units << 39 if unit == 39; units << unit }
        units << 39
      end
      units << 41
      text = units.pack('n*').force_encoding(Encoding::UTF_16BE)
      text.valid_encoding? ? text.encode(Encoding::UTF_8) : text
    end
    def precision = labels.map { CharacterString.sort_key(it).bytesize / 2 }.max
    def scale = 0
    def sql
      quoted = labels.map do |label|
        text = CharacterString.sort_key(label).force_encoding(Encoding::UTF_16BE)
        text.valid_encoding? ? "'#{text.encode(Encoding::UTF_8).gsub("'", "''")}'" : CharacterString.sql(label)
      end
      "ENUM(#{quoted.join(', ')})"
    end

    def value(input, zero_based: false)
      return nil if input.nil?
      return input if input.is_a?(EnumValue) && input.type == self

      input = input.label if input.is_a?(EnumValue)
      index = case input
      when String
        raise Error.new(22018, "Cannot convert binary to ENUM") if BinaryString.binary?(input)

        keys[self.class.clean(input)]
      when Integer, BigDecimal, DecfloatValue
        Type.new("INTEGER", 32, 0).convert(input) - (zero_based ? 0 : 1)
      else raise Error.new(22018, "Cannot convert #{input.class} to ENUM")
      end
      raise Error.new(22030, "ENUM value is not permitted") unless index && (0...labels.length).cover?(index)

      EnumValue.new(self, index, zero_based)
    end

    def convert(input, cast: false, source_type: nil, context: nil)
      value(input, zero_based: context&.zero_based_enums || false)
    end

    alias coerce convert

    def self.common(types)
      unless types.all? { %w[ENUM CHAR VARCHAR TINYINT SMALLINT INTEGER].include?(it.name) }
        raise Error.new(22018, "Incompatible ENUM SQL types")
      end
      types.find { it.is_a?(self) }
    end
  end
end

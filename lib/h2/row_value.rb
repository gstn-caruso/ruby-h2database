# frozen_string_literal: true

require "bigdecimal"

module H2
  class RowValue < Data.define(:values, :type)
    def initialize(values:, type: nil)
      raise Error.new(54011, "Too many row fields") if values.length > 16_384
      if type && (!type.is_a?(RowType) || type.fields.length != values.length)
        raise ArgumentError, "Row descriptor does not match its values"
      end

      super(values: values.map { it.is_a?(String) ? it.dup.freeze : it }.freeze, type: type)
    end

    def to_s
      parts = values.each_with_index.map { |value, index| format_value(value, type&.fields&.fetch(index)) }
      CharacterString.join(['ROW (',CharacterString.join(parts,', '),')'])
    end

    def ==(other) = other.is_a?(RowValue) && values == other.values
    alias eql? ==
    def hash = values.hash

    private

    def format_value(value, field)
      case value
      when nil then "null"
      when true then "TRUE"
      when false then "FALSE"
      when BigDecimal then field&.name == "NUMERIC" ? ArrayType.decimal_text(value, field.scale) : value.to_s("F")
      when Float then JsonValue.float_text(value, real: field&.name == "REAL")
      when String then BinaryString.text(value)
      else value.to_s
      end
    end
  end

  class RowType < Data.define(:fields, :names)
    def initialize(fields:, names: nil)
      raise Error.new(54011, "Too many row fields") if fields.length > 16_384

      names ||= fields.each_index.map { "C#{it + 1}" }
      raise ArgumentError, "Row names and types must have equal lengths" unless names.length == fields.length
      duplicate = names.tally.find { |_name, count| count > 1 }
      raise Error.new(42121, "Duplicate row field #{duplicate.first}") if duplicate

      super(fields: fields.dup.freeze, names: names.map { it.dup.freeze }.freeze)
    end

    def name
      "ROW"
    end

    def type_name = SQLTypeName.metadata(self)
    def precision = 2_147_483_647
    def scale = 0

    def field_index(name)
      names.index(name) || raise(Error.new(42122, "Row field #{name} not found"))
    end

    def convert(value, cast: false, source_type: nil, context: nil)
      return nil if value.nil?
      source_type ||= value.type if value.is_a?(RowValue)
      unless value.is_a?(RowValue)
        raise Error.new(22018, "Cannot convert scalar to a multi-column row") unless fields.length == 1

        value = RowValue.new([value])
      end
      unless value.values.length == fields.length
        raise Error.new(22018, "Row column count does not match")
      end

      RowValue.new(values: fields.each_with_index.map do |type, index|
        field_type = source_type.is_a?(RowType) ? source_type.fields[index] : source_type
        type.convert(value.values[index], cast: cast, source_type: field_type, context: context)
      end, type: self)
    end

    def coerce(value, source_type: nil, context: nil)
      return nil if value.nil?
      source_type ||= value.type if value.is_a?(RowValue)

      value = RowValue.new([value]) unless value.is_a?(RowValue)
      raise Error.new(21002, "Row column count does not match") unless value.values.length == fields.length

      RowValue.new(values: fields.each_with_index.map do |type, index|
        field_type = source_type.is_a?(RowType) ? source_type.fields[index] : source_type
        type.coerce(value.values[index], source_type: field_type, context: context)
      end, type: self)
    end
  end
end

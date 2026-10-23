# frozen_string_literal: true

require "bigdecimal"

module H2
  class RowValue < Data.define(:values)
    def initialize(values:)
      super(values: values.map { it.is_a?(String) ? it.dup.freeze : it }.freeze)
    end

    def to_s
      "ROW (#{values.map { format_value(it) }.join(', ')})"
    end

    private

    def format_value(value)
      case value
      when nil then "null"
      when true then "TRUE"
      when false then "FALSE"
      when BigDecimal then value.to_s("F")
      when String then BinaryString.text(value)
      else value.to_s
      end
    end
  end

  class RowType < Data.define(:fields)
    def initialize(fields:)
      super(fields: fields.freeze)
    end

    def name
      "ROW"
    end

    def convert(value, cast: false, source_type: nil, context: nil)
      return nil if value.nil?
      unless value.is_a?(RowValue)
        raise Error.new(22018, "Cannot convert scalar to a multi-column row") unless fields.length == 1

        value = RowValue.new([value])
      end
      unless value.values.length == fields.length
        raise Error.new(21002, "Row column count does not match")
      end

      RowValue.new(fields.each_with_index.map do |type, index|
        field_type = source_type.is_a?(RowType) ? source_type.fields[index] : source_type
        type.convert(value.values[index], cast: cast, source_type: field_type, context: context)
      end)
    end

    def coerce(value, source_type: nil, context: nil)
      return nil if value.nil?

      value = RowValue.new([value]) unless value.is_a?(RowValue)
      raise Error.new(21002, "Row column count does not match") unless value.values.length == fields.length

      RowValue.new(fields.each_with_index.map do |type, index|
        field_type = source_type.is_a?(RowType) ? source_type.fields[index] : source_type
        type.coerce(value.values[index], source_type: field_type, context: context)
      end)
    end
  end
end

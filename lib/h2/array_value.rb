# frozen_string_literal: true

module H2
  class ArrayValue < Data.define(:values, :element_type)
    MAX_CARDINALITY = 65_536

    def initialize(values:, element_type:)
      raise Error.new(22001, "Array exceeds #{MAX_CARDINALITY} elements") if values.length > MAX_CARDINALITY

      super(values: values.map { it.is_a?(String) ? it.dup.freeze : it }.freeze, element_type: element_type)
    end

    def to_s
      "[#{values.map do |value|
        case value
        when nil then 'null'
        when true then 'TRUE'
        when false then 'FALSE'
        when BigDecimal then ArrayType.decimal_text(value, element_type.scale)
        when String then BinaryString.text(value)
        else value.to_s
        end
      end.join(', ')}]"
    end
  end

  class ArrayType < Data.define(:element_type, :precision)
    def name = "#{SQLTypeName.format(element_type)} ARRAY"
    def scale = 0
    def dimensions = 1 + (element_type.is_a?(ArrayType) ? element_type.dimensions : 0)

    def self.decimal_text(value, scale)
      whole, fraction = value.to_s('F').split('.', 2)
      whole = "0" if value.zero?
      return whole if scale.to_i.zero?

      "#{whole}.#{fraction.to_s.ljust(scale, '0')}"
    end

    def self.element_common(types)
      Type.common(types)
    end

    def self.common(left, right)
      a = left.is_a?(ArrayType) ? left.dimensions : 0
      b = right.is_a?(ArrayType) ? right.dimensions : 0
      return element_common([left, right]) if a.zero? && b.zero?

      precision = if a > b
        [left.precision, 1].max
      elsif b > a
        [right.precision, 1].max
      else
        [left.precision, right.precision].max
      end
      left = left.element_type if a >= b && a.positive?
      right = right.element_type if b >= a && b.positive?
      new(common(left, right), precision)
    end

    def convert(value, cast: false, source_type: nil, context: nil)
      return nil if value.nil?

      source = source_type.is_a?(ArrayType) ? source_type.element_type : source_type
      values = value.is_a?(ArrayValue) ? value.values : [value]
      converted = values.map { element_type.convert(it, cast: cast, source_type: source, context: context) }
      if converted.length > precision
        raise Error.new(22001, "Array exceeds declared cardinality #{precision}") unless cast

        converted = converted.first(precision)
      end
      ArrayValue.new(converted, element_type)
    end

    def coerce(value, source_type: nil, context: nil)
      return nil if value.nil?

      source = source_type.is_a?(ArrayType) ? source_type.element_type : source_type
      values = value.is_a?(ArrayValue) ? value.values : [value]
      ArrayValue.new(values.map { element_type.coerce(it, source_type: source, context: context) }, element_type)
    end
  end
end

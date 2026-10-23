# frozen_string_literal: true

module H2
  class JsonValue < Data.define(:bytes, :node)
    MAX_PRECISION = 1_000_000_000

    def self.parse(text)
      from_node(JsonDocument::Parser.new(text).parse)
    end

    def self.from_node(node)
      new(JsonDocument.render(node).b.freeze, node)
    end

    def self.convert(value, source_type: nil, number_text: nil)
      return value if value.is_a?(self)

      node = case value
      when nil then JsonDocument::Node.new(:literal, 'null')
      when true, false then JsonDocument::Node.new(:literal, value.to_s.freeze)
      when Integer then JsonDocument.number(value.to_s)
      when DecfloatValue then JsonDocument.number(value.json_text)
      when BigDecimal
        text = number_text && number_text.match?(/[eE]/) ? DecfloatValue.parse(number_text).json_text : number_text
        JsonDocument.number(text || ArrayType.decimal_text(value, source_type&.scale || [value.scale, 0].max))
      when Float
        raise Error.new(22018, "Non-finite JSON number") unless value.finite?
        JsonDocument.number(float_text(value, real: source_type&.name == 'REAL'))
      when String
        return parse(value) if BinaryString.binary?(value)
        JsonDocument.quote(value)
        JsonDocument::Node.new(:string, value.encode(Encoding::UTF_8).freeze)
      when UUIDValue, DateValue, TimeValue, TimeTimeZoneValue
        JsonDocument::Node.new(:string, value.to_s.freeze)
      when TimestampValue, TimestampTimeZoneValue
        JsonDocument::Node.new(:string, value.to_s.sub(' ', 'T').freeze)
      when ArrayValue
        type = source_type.is_a?(ArrayType) ? source_type.element_type : value.element_type
        JsonDocument::Node.new(:array, value.values.map { convert(it, source_type: type).node }.freeze)
      else raise Error.new(22018, "Cannot convert #{value.class} to JSON")
      end
      from_node(node)
    end

    def self.float_text(value, real: false)
      return value.to_s unless value.finite?

      text = real ? (1..9).lazy.map { format("%.#{it}g", value) }.find { [it.to_f].pack('f') == [value].pack('f') } : value.to_s
      number = BigDecimal(text)
      if !number.zero? && (number.abs >= 10_000_000 || number.abs < BigDecimal('0.001'))
        sign, digits, _base, exponent = number.split
        (sign.negative? ? '-' : '') + digits[0] + '.' + (digits.length == 1 ? '0' : digits[1..]) + 'E' + (exponent - 1).to_s
      else
        number.to_s('F')
      end
    end

    def initialize(bytes:, node:)
      super(bytes: bytes.b.freeze, node: node)
    end

    private_class_method :new

    def ==(other) = other.is_a?(JsonValue) && bytes == other.bytes
    alias eql? ==
    def hash = bytes.hash

    def to_s = bytes.dup.force_encoding(Encoding::UTF_8)
    def kind = node.kind == :literal || node.kind == :number || node.kind == :string ? :scalar : node.kind
    def sql = "JSON '#{JsonDocument.render(node, ascii: true)}'"
    def null? = node.kind == :literal && node.value == 'null'

    def elements
      node.kind == :array ? node.value.map { self.class.from_node(it) } : []
    end

    def element(index)
      return nil unless node.kind == :array && index.positive? && index <= node.value.length

      self.class.from_node(node.value[index - 1])
    end

    def unique_keys?
      pending = [node]
      until pending.empty?
        item = pending.pop
        if item.kind == :object
          keys = item.value.map(&:first)
          return false if keys.uniq.length != keys.length

          pending.concat(item.value.map(&:last))
        elsif item.kind == :array
          pending.concat(item.value)
        end
      end
      true
    end
  end
end

# frozen_string_literal: true

module H2
  module SQL
    module BitFunctions
      WIDTHS = {"TINYINT" => 8, "SMALLINT" => 16, "INTEGER" => 32, "BIGINT" => 64}.freeze
      BINARY = %w[BINARY VARBINARY].freeze
      BOOLEAN_OPERATIONS = %w[BITAND BITOR BITXOR BITNOT BITNAND BITNOR BITXNOR].freeze
      ARITIES = (BOOLEAN_OPERATIONS + %w[BITGET BITCOUNT LSHIFT RSHIFT ULSHIFT URSHIFT ROTATELEFT ROTATERIGHT]).to_h do |name|
        [name, %w[BITNOT BITCOUNT].include?(name) ? 1..1 : 2..2]
      end.freeze
      AGGREGATES = {"BIT_AND_AGG" => "BITAND", "BIT_OR_AGG" => "BITOR", "BIT_XOR_AGG" => "BITXOR",
        "BIT_NAND_AGG" => "BITNAND", "BIT_NOR_AGG" => "BITNOR", "BIT_XNOR_AGG" => "BITXNOR"}.freeze
      INVERSE = {"BITAND" => "BITNAND", "BITOR" => "BITNOR", "BITXOR" => "BITXNOR",
        "BITNAND" => "BITAND", "BITNOR" => "BITOR", "BITXNOR" => "BITXOR",
        "BIT_AND_AGG" => "BIT_NAND_AGG", "BIT_OR_AGG" => "BIT_NOR_AGG", "BIT_XOR_AGG" => "BIT_XNOR_AGG",
        "BIT_NAND_AGG" => "BIT_AND_AGG", "BIT_NOR_AGG" => "BIT_OR_AGG", "BIT_XNOR_AGG" => "BIT_XOR_AGG"}.freeze
      BYTE_COUNTS = Array.new(256) { it.to_s(2).count('1') }.freeze
      module_function

      def check_type(type)
        raise Error.new(50004, "Bit function argument type is unknown") if type.name == "UNKNOWN"
        return Type.new(type.name, WIDTHS.fetch(type.name), 0) if WIDTHS.key?(type.name)
        return type if (BINARY + ['NULL']).include?(type.name)

        raise Error.new(90008, "Invalid bit function argument type")
      end

      def type(name, arguments)
        return Type.new("BOOLEAN", 1, 0) if name == "BITGET"
        return Type.new("BIGINT", 64, 0) if name == "BITCOUNT"
        return check_type(arguments.first) unless BOOLEAN_OPERATIONS.include?(name)

        types = arguments.map { check_type(it) }
        return types.first if name == "BITNOT"

        binary = types.map { BINARY.include?(it.name) }
        raise Error.new(90008, "Incompatible bit function argument types") if binary.uniq.length > 1
        unless binary.first
          return types.max_by { WIDTHS.fetch(it.name, 0) }
        end
        fixed = types.select { it.name == "BINARY" }
        if fixed.any?
          return Type.new("BINARY", fixed.map { it.precision || 1 }.max, 0)
        end
        precision = types.any? { it.precision.nil? } ? nil : types.map(&:precision).max
        Type.new("VARBINARY", precision, 0)
      end

      def simplify(node)
        return node unless node.name == "BITNOT"

        child = node.arguments.first
        return node unless child.is_a?(Function) || child.is_a?(Aggregate)
        return child.arguments.first if child.name == "BITNOT"

        inverse = INVERSE[child.name]
        inverse ? child.with(name: inverse) : node
      end

      def evaluate(name, result_type, sources, read)
        value = read.call(0)
        return nil if value.nil?
        return bitwise(name, result_type, value) if name == "BITNOT"
        return count(value, sources.first) if name == "BITCOUNT"

        other = read.call(1)
        return nil if other.nil?
        return bitwise(name, result_type, value, other) if BOOLEAN_OPERATIONS.include?(name)

        offset = Type.new("BIGINT", 64, 0).convert(other)
        return get(value, sources.first, offset) if name == "BITGET"
        return rotate(value, sources.first, offset, name == "ROTATERIGHT") if name.start_with?("ROTATE")

        if name == "RSHIFT"
          offset = offset == -(1 << 63) ? (1 << 63) - 1 : -offset
        elsif name == "URSHIFT"
          offset = signed(-offset, 64)
        end
        shift(value, sources.first, offset, name.start_with?('U'))
      end

      def bitwise(name, type, left, right = nil)
        if BINARY.include?(type.name)
          length = name == "BITNOT" ? left.bytesize : [[left.bytesize,right.bytesize].max, type.precision || 1_000_000_000].min
          return Array.new(length) { |i| operation(name, left.getbyte(i) || 0, right&.getbyte(i) || 0) & 255 }.pack('C*').b.freeze
        end
        signed(operation(name, left, right), WIDTHS.fetch(type.name))
      end

      def operation(name, left, right)
        case name
        when "BITAND" then left & right
        when "BITOR" then left | right
        when "BITXOR" then left ^ right
        when "BITNOT" then ~left
        when "BITNAND" then ~(left & right)
        when "BITNOR" then ~(left | right)
        when "BITXNOR" then ~(left ^ right)
        end
      end

      def get(value, type, offset)
        return false if offset.negative?
        if BINARY.include?(type.name)
          byte = value.getbyte(offset >> 3)
          return byte && (byte & (1 << (offset & 7))) != 0 ? true : false
        end
        width = WIDTHS[type.name]
        raise Error.new(90008, "Invalid BITGET value") unless width
        return false if type.name != "BIGINT" && offset >= width

        (value & (1 << (offset & (width - 1)))) != 0
      end

      def count(value, type)
        return value.bytes.sum { BYTE_COUNTS[it] } if BINARY.include?(type.name)

        width = WIDTHS[type.name]
        raise Error.new(90008, "Invalid BITCOUNT value") unless width

        (value & ((1 << width) - 1)).to_s(2).count('1')
      end

      def shift(value, type, offset, unsigned)
        return value if offset.zero?

        binary = BINARY.include?(type.name)
        width = binary ? value.bytesize * 8 : WIDTHS.fetch(type.name)
        return value if width.zero?

        integer = binary ? value.unpack1('H*').to_i(16) : value
        result = if offset >= width then 0
        elsif offset <= -width then !binary && !unsigned && integer.negative? ? -1 : 0
        elsif offset.positive? then integer << offset
        else
          integer &= (1 << width) - 1 if binary || unsigned
          integer >> -offset
        end
        pack(result, width, binary)
      end

      def rotate(value, type, offset, right)
        binary = BINARY.include?(type.name)
        width = binary ? value.bytesize * 8 : WIDTHS.fetch(type.name)
        return value if width.zero?

        offset = -offset if right
        offset %= width
        return value if offset.zero?

        integer = binary ? value.unpack1('H*').to_i(16) : value & ((1 << width) - 1)
        pack((integer << offset) | (integer >> (width - offset)), width, binary)
      end

      def signed(value, width)
        (value + (1 << (width - 1))) % (1 << width) - (1 << (width - 1))
      end

      def pack(value, width, binary)
        return signed(value, width) unless binary

        [(value & ((1 << width) - 1)).to_s(16).rjust(width / 4, '0')].pack('H*').b.freeze
      end

      def aggregate(name, values, type)
        return nil if values.empty?

        operation = AGGREGATES.fetch(name)
        inverse = %w[BITNAND BITNOR BITXNOR].include?(operation)
        operation = INVERSE.fetch(operation) if inverse
        value = values.reduce { |left, right| bitwise(operation, type, left, right) }
        inverse ? bitwise("BITNOT", type, value) : value
      end

      def literal(value, type)
        type = Type.new(type.name, value.bytesize, 0) if value && BINARY.include?(type.name)
        TypedLiteral.new(value, type, value.nil? && type.name != "NULL")
      end
    end
  end
end

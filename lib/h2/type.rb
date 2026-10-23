# frozen_string_literal: true

module H2
  class Type < Data.define(:name, :precision, :scale, :declared_scale, :declared_name, :declared_precision)
    def initialize(name:, precision:, scale:, declared_scale: nil, declared_name: nil, declared_precision: nil)
      super
    end

    ORDER = (%w[NULL CHAR VARCHAR BINARY VARBINARY BOOLEAN TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE DECFLOAT] + Temporal::NAMES + Intervals::NAMES + %w[JSON UUID]).freeze
    INTEGER_LIMITS = {"TINYINT" => (-128..127), "SMALLINT" => (-32_768..32_767),
      "INTEGER" => (-2_147_483_648..2_147_483_647),
      "BIGINT" => (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)}.freeze
    NUMERIC_WIDTHS = {"BOOLEAN" => [1, 0], "TINYINT" => [3, 0], "SMALLINT" => [5, 0], "INTEGER" => [10, 0],
      "BIGINT" => [19, 0], "REAL" => [85, 46], "DOUBLE" => [634, 325]}.freeze

    def type_name = declared_name == "DECIMAL" ? "DECIMAL" : name

    def self.numeric_info(type)
      type.name == "NUMERIC" ? [type.precision || 100_000, type.scale || 0] : NUMERIC_WIDTHS.fetch(type.name, [100_000, 50_000])
    end

    def self.decfloat_precision(type)
      case type.name
      when "BOOLEAN", "NUMERIC", "DECFLOAT" then type.precision || 100_000
      when "REAL" then 7
      when "DOUBLE" then 17
      else NUMERIC_WIDTHS.fetch(type.name, [100_000]).first
      end
    end

    def self.check_comparable(left, right)
      a, b = left, right
      a = a.fields.first while a.is_a?(RowType) && a.fields.length == 1
      b = b.fields.first while b.is_a?(RowType) && b.fields.length == 1
      if a.is_a?(ArrayType) || b.is_a?(ArrayType)
        if a.is_a?(ArrayType) && b.is_a?(ArrayType)
          check_comparable(a.element_type, b.element_type)
        elsif ![a, b].any? { it && %w[NULL UNKNOWN].include?(it.name) }
          raise Error.new(90110, "SQL array types are not comparable")
        end
        return common([left, right])
      end
      if left.is_a?(RowType) && right.is_a?(RowType) && left.fields.length == right.fields.length
        left.fields.zip(right.fields).each { check_comparable(*it) }
      elsif left && right && !left.is_a?(RowType) && !right.is_a?(RowType)
        names = [left.name, right.name]
        if names.include?("JSON") && (names - %w[NULL UNKNOWN CHAR VARCHAR BINARY VARBINARY JSON]).any?
          raise Error.new(90110, "SQL JSON types are not comparable")
        end
        interval_names = names.select { Intervals.name?(it) }
        if !interval_names.empty?
          allowed = Intervals::NAMES + %w[NULL UNKNOWN CHAR VARCHAR]
          families = interval_names.map { IntervalUnits.year_month?(IntervalUnits.ordinal(it.delete_prefix("INTERVAL "))) }
          if (names - allowed).any? || families.uniq.length > 1
            raise Error.new(90110, "SQL interval types are not comparable")
          end
        end
        binary = (names & %w[BINARY VARBINARY]).any?
        uuid = names.include?("UUID")
        temporal = (names & Temporal::NAMES).any?
        if temporal && ((names - (%w[NULL UNKNOWN CHAR VARCHAR] + Temporal::NAMES)).any? ||
            (names.include?("DATE") && names.any? { Temporal.time_type?(it) }))
          raise Error.new(90110, "SQL temporal types are not comparable")
        end
        if (binary && (names - %w[NULL UNKNOWN BINARY VARBINARY JSON UUID]).any?) ||
            (uuid && (names - %w[NULL UNKNOWN CHAR VARCHAR BINARY VARBINARY UUID]).any?)
          raise Error.new(90110, "SQL types #{names.join(', ')} are not comparable")
        end
      end
      common([left, right])
    end

    def self.common(types)
      types = types.compact.reject { it.name == "NULL" }
      return new("NULL", nil, nil) if types.empty?
      known = types.reject { it.name == "UNKNOWN" }
      return new("UNKNOWN", nil, nil) if known.empty?

      types = known
      return types.first if types.length == 1
      if types.any? { it.is_a?(RowType) }
        width = types.find { it.is_a?(RowType) }.fields.length
        types = types.map { it.is_a?(RowType) ? it : RowType.new([it]) } if width == 1
        unless types.all? { it.is_a?(RowType) && it.fields.length == types.first.fields.length }
          raise Error.new(90110, "Row types are not comparable")
        end

        return RowType.new(Array.new(types.first.fields.length) { |index| common(types.map { it.fields[index] }) })
      end
      return types.reduce { ArrayType.common(_1, _2) } if types.any? { it.is_a?(ArrayType) }
      return Intervals.common(types) if types.any? { Intervals.name?(it.name) }

      name = types.max_by { ORDER.index(it.name) || -1 }.name
      names = types.map(&:name)
      if %w[REAL DOUBLE].include?(name) && (names & %w[BIGINT NUMERIC]).any?
        name = "DECFLOAT"
      elsif name == "REAL" && names.include?("INTEGER")
        name = "DOUBLE"
      end
      if (names & Temporal::NAMES).any?
        if (names - (%w[CHAR VARCHAR] + Temporal::NAMES)).any?
          raise Error.new(22018, "Incompatible temporal SQL types")
        end
        name = Temporal.common_name(names)
      end
      if (names.include?("UUID") && (names - %w[UUID CHAR VARCHAR BINARY VARBINARY]).any?) ||
          ((names & %w[BINARY VARBINARY]).any? && (names & %w[BOOLEAN TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE DECFLOAT]).any?)
        raise Error.new(22018, "Incompatible SQL types #{names.join(', ')}")
      end
      precision = types.any? { it.precision.nil? } ? nil : types.map(&:precision).max
      scale = types.filter_map(&:scale).max
      if name == "NUMERIC"
        numeric = types.map { numeric_info(it) }
        scale = numeric.map(&:last).max
        precision = [numeric.map { |width, source_scale| width + scale - source_scale }.max, 100_000].min
      elsif name == "DECFLOAT"
        precision = types.map { decfloat_precision(it) }.max
        scale = 0
      end
      return Temporal.type(name, scale) if Temporal::NAMES.include?(name)

      new(name, precision, scale)
    end

    def convert(value, cast: false, source_type: nil, context: nil)
      return nil if value.nil?
      if value.is_a?(JsonValue) && !%w[NULL CHAR VARCHAR BINARY VARBINARY JSON].include?(name)
        raise Error.new(22018, "Cannot convert JSON to #{name}")
      end

      case name
      when "NULL"
        nil
      when "JSON"
        json = JsonValue.convert(value, source_type: source_type)
        raise Error.new(22001, "JSON exceeds declared precision") if precision && json.bytes.bytesize > precision

        json
      when "DECFLOAT" then DecfloatValue.convert(value, source_type: source_type).round(precision || 100_000)
      when *INTEGER_LIMITS.keys
        integer(value)
      when "VARCHAR", "CHAR"
        text = case value
        when true then "TRUE"
        when false then "FALSE"
        when BigDecimal then ArrayType.decimal_text(value, source_type&.scale || [value.scale, 0].max)
        when Float then JsonValue.float_text(value, real: source_type&.name == "REAL")
        else BinaryString.text(value)
        end
        CharacterString.fit(text, precision, pad: name == "CHAR", cast: cast)
      when "BINARY", "VARBINARY"
        bytes = BinaryString.encode(value, source_type: source_type)
        if precision && bytes.bytesize > precision
          raise Error.new(22001, "Value too long for #{name}(#{precision})") unless cast

          bytes = bytes.byteslice(0, precision)
        end
        bytes = bytes.ljust(precision, "\x00".b) if name == "BINARY" && precision
        bytes.b.freeze
      when "UUID"
        return value if value.is_a?(UUIDValue)

        BinaryString.binary?(value) ? UUIDValue.new(value) : UUIDValue.parse(value)
      when *Temporal::NAMES
        value = Temporal.convert(value, name, context: context)
        name == "DATE" ? value : value.round(scale || (Temporal.time_type?(name) ? 0 : 6))
      when *Intervals::NAMES
        Intervals.convert(value, Intervals.qualifier(self)).round(self)
      when "NUMERIC"
        input = decimal_input(value, source_type)
        decimal = input.is_a?(String) ? NumericText.decimal(input) : BigDecimal(input.to_s)
        raise Error.new(22018, "Non-finite NUMERIC value") unless decimal.finite?

        decimal = decimal.round(scale || 0, BigDecimal::ROUND_HALF_UP)
        if precision && decimal.abs >= BigDecimal("1E#{precision - (scale || 0)}")
          raise Error.new(22001, "Value exceeds NUMERIC(#{precision}, #{scale || 0})")
        end
        decimal
      when "REAL"
        input = numeric_input(value)
        number = input.is_a?(String) ? NumericText.floating(input, real: true) : NumericText.real_value(input)
        return Float::NAN if number.nan?
        number.zero? ? 0.0 : number
      when "DOUBLE"
        number = floating(value)
        return Float::NAN if number.nan?
        number.zero? ? 0.0 : number
      when "BOOLEAN"
        boolean(value)
      else
        raise Error.new(50100, "Unsupported type #{name}")
      end
    rescue ArgumentError, TypeError, FloatDomainError
      raise Error.new(22018, "Cannot convert #{value.inspect} to #{name}")
    end

    def coerce(value, source_type: nil, context: nil)
      return nil if value.nil?

      case name
      when "JSON" then JsonValue.convert(value, source_type: source_type)
      when "DECFLOAT" then DecfloatValue.convert(value, source_type: source_type)
      when "CHAR"
        CharacterString.trim_spaces(with(precision: nil).convert(value, source_type: source_type, context: context))
      when "VARCHAR", "BINARY", "VARBINARY"
        with(precision: nil).convert(value, source_type: source_type, context: context)
      when *Temporal::NAMES
        Temporal.convert(value, name, context: context)
      when *Intervals::NAMES
        Intervals.convert(value, Intervals.qualifier(self))
      when "NUMERIC"
        input = decimal_input(value, source_type)
        number = input.is_a?(String) ? NumericText.decimal(input) : BigDecimal(input.to_s)
        raise Error.new(22018, "Non-finite NUMERIC value") unless number.finite?

        number
      else convert(value, source_type: source_type, context: context)
      end
    rescue ArgumentError, TypeError
      raise Error.new(22018, "Cannot coerce #{value.inspect} to #{name}")
    end

    private

    def decimal_input(value, source_type)
      return JsonValue.float_text(value, real: source_type&.name == "REAL") if value.is_a?(Float)

      numeric_input(value)
    end

    def floating(value)
      value = numeric_input(value)
      return NumericText.floating(value) if value.is_a?(String)
      Float(value)
    rescue EncodingError
      raise Error.new(22018, "Invalid floating-point text encoding")
    end

    def numeric_input(value)
      return value.to_d if value.is_a?(DecfloatValue)
      return value.to_d if value.is_a?(IntervalValue)
      if BinaryString.binary?(value) || value.is_a?(UUIDValue)
        raise Error.new(22018, "Cannot convert binary or UUID to #{name}")
      end
      return 1 if value == true
      return 0 if value == false

      value
    end

    def integer(value)
      if value.is_a?(DecfloatValue) && !value.finite?
        raise Error.new(22018, "Cannot convert non-finite DECFLOAT to integer")
      end
      value = value.to_d if value.is_a?(DecfloatValue)
      if BinaryString.binary?(value)
        format = BinaryString::INTEGER_PACK.fetch(name)
        width = {"TINYINT" => 1, "SMALLINT" => 2, "INTEGER" => 4, "BIGINT" => 8}.fetch(name)
        raise Error.new(22018, "#{name} requires #{width} binary bytes") unless value.bytesize == width

        return value.unpack1(format)
      end
      number = case value
      when IntervalValue then value.to_i
      when Integer then value
      when Float
        if value > INTEGER_LIMITS.fetch("BIGINT").end.to_f || value < INTEGER_LIMITS.fetch("BIGINT").begin.to_f
          raise Error.new(22003, "Floating point value is outside BIGINT range")
        end
        value.nan? ? 0 : [[(value.to_r + Rational(1,2)).floor, INTEGER_LIMITS.fetch("BIGINT").begin].max, INTEGER_LIMITS.fetch("BIGINT").end].min
      when Numeric
        unless INTEGER_LIMITS.fetch("BIGINT").cover?(value)
          raise Error.new(22003, "Decimal value is outside BIGINT range")
        end
        value.round(0, half: :up).to_i
      when true then 1
      when false then 0
      else NumericText.integer(value.to_s, INTEGER_LIMITS.fetch(name))
      end
      raise Error.new(22003, "#{number} is outside #{name} range") unless INTEGER_LIMITS.fetch(name).cover?(number)

      number
    end

    def boolean(value)
      value = value.to_d if value.is_a?(DecfloatValue)
      raise Error.new(22018, "Cannot convert INTERVAL to BOOLEAN") if value.is_a?(IntervalValue)
      if BinaryString.binary?(value) || value.is_a?(UUIDValue)
        raise Error.new(22018, "Cannot convert binary or UUID to BOOLEAN")
      end
      case value
      when true, false then value
      when Numeric then !value.zero? && !(value.respond_to?(:nan?) && value.nan?)
      else
        text = NumericText.trim(value.to_s)
        return true if text.match?(/\A(?:true|t|yes|y)\z/i)
        return false if text.match?(/\A(?:false|f|no|n)\z/i)

        number = NumericText.decimal(text)
        raise Error.new(22018, "Cannot convert #{value.inspect} to BOOLEAN") unless number.finite?

        !number.zero?
      end
    end
  end

  Column = Data.define(:name, :type, :nullable, :default)
  Key = Data.define(:columns, :primary)
end

# frozen_string_literal: true

module H2
  class Type < Data.define(:name, :precision, :scale)
    ORDER = (%w[NULL CHAR VARCHAR BINARY VARBINARY BOOLEAN TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE] + Temporal::NAMES + Intervals::NAMES + ["UUID"]).freeze
    INTEGER_LIMITS = {"TINYINT" => (-128..127), "SMALLINT" => (-32_768..32_767),
      "INTEGER" => (-2_147_483_648..2_147_483_647),
      "BIGINT" => (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)}.freeze

    def self.check_comparable(left, right)
      if left.is_a?(RowType) && right.is_a?(RowType) && left.fields.length == right.fields.length
        left.fields.zip(right.fields).each { check_comparable(*it) }
      elsif left && right && !left.is_a?(RowType) && !right.is_a?(RowType)
        names = [left.name, right.name]
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
        if (binary && (names - %w[NULL UNKNOWN BINARY VARBINARY UUID]).any?) ||
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
      if types.any? { it.is_a?(RowType) }
        width = types.find { it.is_a?(RowType) }.fields.length
        types = types.map { it.is_a?(RowType) ? it : RowType.new([it]) } if width == 1
        unless types.all? { it.is_a?(RowType) && it.fields.length == types.first.fields.length }
          raise Error.new(90110, "Row types are not comparable")
        end

        return RowType.new(Array.new(types.first.fields.length) { |index| common(types.map { it.fields[index] }) })
      end
      return Intervals.common(types) if types.any? { Intervals.name?(it.name) }

      name = types.max_by { ORDER.index(it.name) || -1 }.name
      names = types.map(&:name)
      if (names & Temporal::NAMES).any?
        if (names - (%w[CHAR VARCHAR] + Temporal::NAMES)).any?
          raise Error.new(22018, "Incompatible temporal SQL types")
        end
        name = Temporal.common_name(names)
      end
      if (names.include?("UUID") && (names - %w[UUID CHAR VARCHAR BINARY VARBINARY]).any?) ||
          ((names & %w[BINARY VARBINARY]).any? && (names & %w[BOOLEAN TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE]).any?)
        raise Error.new(22018, "Incompatible SQL types #{names.join(', ')}")
      end
      precision = types.any? { it.precision.nil? } ? nil : types.map(&:precision).max
      scale = types.filter_map(&:scale).max
      if name == "NUMERIC"
        precision = 100_000
        scale ||= 0
      end
      return Temporal.type(name, scale) if Temporal::NAMES.include?(name)

      new(name, precision, scale)
    end

    def convert(value, cast: false, source_type: nil, context: nil)
      return nil if value.nil?

      case name
      when "NULL"
        raise Error.new(22018, "Cannot assign a non-NULL value to NULL type")
      when *INTEGER_LIMITS.keys
        integer(value)
      when "VARCHAR", "CHAR"
        text = case value
        when true then "TRUE"
        when false then "FALSE"
        when BigDecimal then value.to_s("F")
        else BinaryString.text(value)
        end
        if precision && text.length > precision
          unless cast || (name == "CHAR" && text[precision..].match?(/\A *\z/))
            raise Error.new(22001, "Value too long for #{name}(#{precision})")
          end
          text = text[0, precision]
        end

        (name == "CHAR" && precision ? text.ljust(precision) : text).dup.freeze
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
        decimal = BigDecimal(numeric_input(value).to_s)
        raise Error.new(22018, "Non-finite NUMERIC value") unless decimal.finite?

        decimal = decimal.round(scale || 0, BigDecimal::ROUND_HALF_UP)
        if precision && decimal.abs >= BigDecimal("1E#{precision - (scale || 0)}")
          raise Error.new(22001, "Value exceeds NUMERIC(#{precision}, #{scale || 0})")
        end
        decimal
      when "REAL"
        [Float(numeric_input(value))].pack("f").unpack1("f")
      when "DOUBLE"
        Float(numeric_input(value))
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
      when "CHAR"
        CharacterString.trim_spaces(with(precision: nil).convert(value, source_type: source_type, context: context))
      when "VARCHAR", "BINARY", "VARBINARY"
        with(precision: nil).convert(value, source_type: source_type, context: context)
      when *Temporal::NAMES
        Temporal.convert(value, name, context: context)
      when *Intervals::NAMES
        Intervals.convert(value, Intervals.qualifier(self))
      when "NUMERIC"
        number = BigDecimal(numeric_input(value).to_s)
        raise Error.new(22018, "Non-finite NUMERIC value") unless number.finite?

        number
      else convert(value, source_type: source_type, context: context)
      end
    rescue ArgumentError, TypeError
      raise Error.new(22018, "Cannot coerce #{value.inspect} to #{name}")
    end

    private

    def numeric_input(value)
      return value.to_d if value.is_a?(IntervalValue)
      if BinaryString.binary?(value) || value.is_a?(UUIDValue)
        raise Error.new(22018, "Cannot convert binary or UUID to #{name}")
      end
      return 1 if value == true
      return 0 if value == false

      value
    end

    def integer(value)
      if BinaryString.binary?(value)
        format = BinaryString::INTEGER_PACK.fetch(name)
        width = {"TINYINT" => 1, "SMALLINT" => 2, "INTEGER" => 4, "BIGINT" => 8}.fetch(name)
        raise Error.new(22018, "#{name} requires #{width} binary bytes") unless value.bytesize == width

        return value.unpack1(format)
      end
      number = case value
      when IntervalValue then value.to_i
      when Integer then value
      when Numeric then value.round(0, half: :up).to_i
      when true then 1
      when false then 0
      else Integer(value.to_s.strip, 10)
      end
      raise Error.new(22003, "#{number} is outside #{name} range") unless INTEGER_LIMITS.fetch(name).cover?(number)

      number
    end

    def boolean(value)
      raise Error.new(22018, "Cannot convert INTERVAL to BOOLEAN") if value.is_a?(IntervalValue)
      if BinaryString.binary?(value) || value.is_a?(UUIDValue)
        raise Error.new(22018, "Cannot convert binary or UUID to BOOLEAN")
      end
      case value
      when true, false then value
      when Numeric then !value.zero?
      else
        text = value.to_s.strip
        return true if text.match?(/\A(?:true|t|yes|y)\z/i)
        return false if text.match?(/\A(?:false|f|no|n)\z/i)

        number = BigDecimal(text)
        raise Error.new(22018, "Cannot convert #{value.inspect} to BOOLEAN") unless number.finite?

        !number.zero?
      end
    end
  end

  Column = Data.define(:name, :type, :nullable, :default)
  Key = Data.define(:columns, :primary)
end

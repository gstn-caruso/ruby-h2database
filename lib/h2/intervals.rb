# frozen_string_literal: true

module H2
  module Intervals
    NAMES = IntervalUnits::QUALIFIERS.map { "INTERVAL #{it}" }.freeze
    module_function

    def name?(name)
      NAMES.include?(name)
    end

    def type(qualifier, precision = 2, scale = nil)
      Type.new("INTERVAL #{qualifier}", precision, IntervalUnits.seconds?(IntervalUnits.ordinal(qualifier)) ? (scale || 6) : 0)
    end

    def qualifier(type)
      type.name.delete_prefix("INTERVAL ")
    end

    def convert(value, qualifier)
      ordinal = IntervalUnits.ordinal(qualifier)
      if value.is_a?(IntervalValue)
        unless value.year_month? == IntervalUnits.year_month?(ordinal)
          raise Error.new(22018, "Incompatible interval families")
        end
        return IntervalValue.from_absolute(qualifier, value.absolute)
      elsif value.is_a?(String) && !BinaryString.binary?(value)
        begin
          match = /\A\s*INTERVAL\s*([+-]?)\s*'([^']*)'\s*([A-Z]+(?:\s+TO\s+[A-Z]+)?)\s*\z/i.match(value)
          interval = match ? IntervalValue.parse(match[3].upcase.gsub(/\s+/, " "), match[2], negative: match[1] == "-") : IntervalValue.parse(qualifier, value)
          return convert(interval, qualifier)
        rescue Error
          raise Error.new(22007, "Invalid INTERVAL text")
        end
      elsif value.is_a?(Numeric)
        if !value.is_a?(Integer) && ordinal >= 5
          absolute = (BigDecimal(value.to_s) * IntervalUnits::LEADING[ordinal]).round(0, BigDecimal::ROUND_HALF_UP).to_i
          return IntervalValue.from_absolute(qualifier, absolute)
        end
        unless Type::INTEGER_LIMITS.fetch("BIGINT").cover?(value)
          raise Error.new(22003, "Interval numeric value exceeds BIGINT")
        end
        number = value.is_a?(Float) ? value.floor + (value - value.floor >= 0.5 ? 1 : 0) : value.round(0, half: :up).to_i
        return IntervalValue.new(qualifier, number.negative?, number.abs, 0)
      end
      raise Error.new(22018, "Cannot convert #{value.class} to INTERVAL")
    end

    def common(types)
      intervals = types.select { name?(it.name) }
      allowed = NAMES + %w[CHAR VARCHAR TINYINT SMALLINT INTEGER BIGINT NUMERIC REAL DOUBLE]
      raise Error.new(22018, "Incompatible interval SQL types") unless types.all? { allowed.include?(it.name) }

      ordinals = intervals.map { IntervalUnits.ordinal(qualifier(it)) }
      ordinal = IntervalUnits.common(ordinals)
      type(IntervalUnits::QUALIFIERS[ordinal], intervals.map { it.precision || 18 }.max, intervals.map { it.scale || 0 }.max)
    rescue ArgumentError
      raise Error.new(22018, "Incompatible interval families")
    end

    def sql(type, explicit: false)
      fields = qualifier(type).split(" TO ")
      precision = type.precision || 2
      scale = type.scale || 0
      if fields == ["SECOND"]
        fields[0] += "(#{precision}, #{scale})" if explicit || precision != 2 || scale != 6
      else
        fields[0] += "(#{precision})" if explicit || precision != 2
        fields[-1] += "(#{scale})" if fields.length > 1 && fields[-1] == "SECOND" && (explicit || scale != 6)
      end
      "INTERVAL #{fields.join(' TO ')}"
    end
  end
end

# frozen_string_literal: true

module H2
  class Type < Data.define(:name, :precision, :scale)
    INTEGER_LIMITS = {"TINYINT" => (-128..127), "SMALLINT" => (-32_768..32_767),
      "INTEGER" => (-2_147_483_648..2_147_483_647),
      "BIGINT" => (-9_223_372_036_854_775_808..9_223_372_036_854_775_807)}.freeze

    def convert(value, cast: false)
      return nil if value.nil?

      case name
      when *INTEGER_LIMITS.keys
        integer(value)
      when "VARCHAR", "CHAR"
        text = case value
        when true then "TRUE"
        when false then "FALSE"
        when BigDecimal then value.to_s("F")
        else value.to_s
        end
        if precision && text.length > precision
          unless cast || (name == "CHAR" && text[precision..].match?(/\A *\z/))
            raise Error.new(22001, "Value too long for #{name}(#{precision})")
          end
          text = text[0, precision]
        end

        (name == "CHAR" && precision ? text.ljust(precision) : text).dup.freeze
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

    private

    def numeric_input(value)
      return 1 if value == true
      return 0 if value == false

      value
    end

    def integer(value)
      number = case value
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

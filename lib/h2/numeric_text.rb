# frozen_string_literal: true

module H2
  module NumericText
    DECIMAL = /\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[Ee][+-]?[0-9]+)?\z/
    HEX = /\A([+-]?)0[xX]([0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)[pP]([+-]?[0-9]+)\z/
    SPECIALS = {"NaN" => Float::NAN, "+NaN" => Float::NAN, "-NaN" => Float::NAN,
      "Infinity" => Float::INFINITY, "+Infinity" => Float::INFINITY, "-Infinity" => -Float::INFINITY}.freeze
    module_function

    def trim(value)
      value.encode(Encoding::UTF_8).sub(/\A[\x00-\x20]+/, '').sub(/[\x00-\x20]+\z/, '')
    rescue EncodingError
      raise Error.new(22018, "Invalid numeric text encoding")
    end

    def digits(text)
      text.gsub(/\p{Nd}/) do |digit|
        point = digit.ord
        next digit if point > 0xffff

        first = point
        first -= 1 while (first - 1).chr(Encoding::UTF_8).match?(/\p{Nd}/)
        ((point - first) % 10).to_s
      end
    end

    def integer(value, range)
      text = digits(trim(value))
      raise Error.new(22018, "Invalid integer text") unless text.match?(/\A[+-]?[0-9]+\z/)

      number = Integer(text, 10)
      raise Error.new(22018, "Integer text outside target range") unless range.cover?(number)

      number
    end

    def decimal(value)
      text = digits(trim(value))
      raise Error.new(22018, "Invalid decimal text") unless DECIMAL.match?(text)

      mantissa, exponent = text.split(/[Ee]/)
      scale = (mantissa.split('.', 2)[1]&.length || 0) - exponent.to_i
      raise Error.new(22018, "Decimal scale outside range") unless (-(1 << 31)...(1 << 31)).cover?(scale)

      BigDecimal(text)
    end

    def floating(value, real: false)
      text = trim(value)
      return SPECIALS.fetch(text) if SPECIALS.key?(text)

      text = text.sub(/[fFdD]\z/, '')
      hex = HEX.match(text)
      raise Error.new(22018, "Invalid floating-point text") unless hex || DECIMAL.match?(text)
      return Float(text) unless real
      return real_value(BigDecimal(text)) unless hex

      fraction = hex[2].split('.', 2)[1]&.length || 0
      coefficient = Integer(hex[2].delete('.'), 16)
      exponent = hex[3].to_i - fraction * 4
      return 0.0 if coefficient.zero?

      negative = hex[1] == '-'
      power = coefficient.bit_length - 1 + exponent
      return negative ? -Float::INFINITY : Float::INFINITY if power > 127
      return 0.0 if power < -150

      ratio = exponent >= 0 ? Rational(coefficient << exponent) : Rational(coefficient, 1 << -exponent)
      real_ratio(negative ? -ratio : ratio)
    end

    def real_value(value)
      raise Error.new(22018, "Cannot convert value to REAL") unless value.is_a?(Numeric)

      return [value].pack('g').unpack1('g') if value.is_a?(Float)
      return value.to_f unless value.finite?
      return 0.0 if value.zero?
      return value.negative? ? -Float::INFINITY : Float::INFINITY if value.is_a?(BigDecimal) && value.abs.exponent > 39
      return 0.0 if value.is_a?(BigDecimal) && value.abs.exponent < -45

      real_ratio(value.to_r)
    end

    def real_ratio(value)
      negative = value.negative?
      numerator, denominator = value.abs.numerator, value.denominator
      return 0.0 if numerator.zero?

      exponent = numerator.bit_length - denominator.bit_length
      lower = exponent >= 0 ? numerator < (denominator << exponent) : (numerator << -exponent) < denominator
      exponent -= 1 if lower
      shift = [exponent - 23, -149].max
      shift >= 0 ? denominator <<= shift : numerator <<= -shift
      significand, remainder = numerator.divmod(denominator)
      significand += 1 if remainder * 2 > denominator || (remainder * 2 == denominator && significand.odd?)
      if significand >= (1 << 24)
        significand >>= 1
        exponent += 1
      end
      bits = if exponent > 127 then 0x7f800000
      elsif exponent < -126 then significand
      else ((exponent + 127) << 23) | (significand - (1 << 23))
      end
      bits |= 0x80000000 if negative && bits != 0
      [bits].pack('N').unpack1('g')
    end
  end
end

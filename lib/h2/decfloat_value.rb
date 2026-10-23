# frozen_string_literal: true

module H2
  class DecfloatValue < Data.define(:unscaled, :scale, :special)
    def initialize(unscaled:, scale:, special:)
      unless special
        if unscaled.zero?
          scale = 0
        else
          digits = unscaled.to_s
          trailing_zeros = digits.length - digits.rindex(/[^0]/) - 1
          if trailing_zeros.positive?
            unscaled = Integer(digits[0...-trailing_zeros], 10)
            scale -= trailing_zeros
          end
        end
        raise Error.new(50000, "DECFLOAT scale overflow") unless (-(1 << 31)...(1 << 31)).cover?(scale)
        raise Error.new(22001, "DECFLOAT exceeds maximum precision") if unscaled.abs.to_s.length > 100_000
      end
      super
    end

    def self.parse(text)
      text = text.encode(Encoding::UTF_8).sub(/\A[\x00-\x20]+/, '').sub(/[\x00-\x20]+\z/, '')
      unless text.ascii_only?
        text = text.gsub(/\p{Nd}/) do |digit|
          point = digit.ord
          next digit if point > 0xffff

          first = point
          first -= 1 while (first - 1).chr(Encoding::UTF_8).match?(/\p{Nd}/)
          ((point - first) % 10).to_s
        end
      end
      special = {"Infinity" => :infinity, "+Infinity" => :infinity, "-Infinity" => :negative_infinity,
        "NaN" => :nan, "+NaN" => :nan, "-NaN" => :nan}[text]
      return new(0, 0, special) if special
      unless text.match?(/\A[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[Ee][+-]?\d+)?\z/)
        raise Error.new(22018, "Invalid DECFLOAT")
      end
      mantissa, exponent = text.split(/[eE]/)
      scale = (mantissa.split('.', 2)[1]&.length || 0) - exponent.to_i
      raise Error.new(22018, "DECFLOAT scale out of range") unless (-(1 << 31)...(1 << 31)).cover?(scale)

      new(Integer(mantissa.delete('.'), 10), scale, nil)
    rescue EncodingError
      raise Error.new(22018, "Invalid DECFLOAT text encoding")
    end

    def self.convert(value, source_type: nil)
      return value if value.is_a?(self)
      text = case value
      when BigDecimal then ArrayType.decimal_text(value, source_type&.scale || [value.scale, 0].max)
      when Float then value.finite? ? JsonValue.float_text(value, real: source_type&.name == 'REAL') : value.to_s
      when true then '1'
      when false then '0'
      when Integer then value.to_s
      when String
        raise Error.new(22018, "Cannot convert binary to DECFLOAT") if BinaryString.binary?(value)
        value
      else raise Error.new(22018, "Cannot convert #{value.class} to DECFLOAT")
      end
      parse(text)
    end

    def precision = special ? 1 : unscaled.abs.to_s.length
    def finite? = special.nil?
    def zero? = finite? && unscaled.zero?
    def signum = special ? {infinity: 1, negative_infinity: -1, nan: 0}.fetch(special) : unscaled <=> 0
    def abs = signum.negative? ? negate : self

    def add(other)
      if special || other.special
        return other unless special
        return self unless other.special
        return special == other.special ? self : self.class.new(0, 0, :nan)
      end
      return other if zero?
      return self if other.zero?

      target_scale = [scale, other.scale].max
      if (scale - other.scale).abs > 200_000
        raise Error.new(22001, "DECFLOAT sum exceeds maximum precision")
      end
      self.class.new(unscaled * 10**(target_scale - scale) + other.unscaled * 10**(target_scale - other.scale), target_scale, nil)
    end

    def subtract(other) = add(other.negate)

    def multiply(other)
      if special || other.special
        sign = signum * other.signum
        return self.class.new(0, 0, sign.zero? ? :nan : sign.positive? ? :infinity : :negative_infinity)
      end

      self.class.new(unscaled * other.unscaled, scale + other.scale, nil)
    end

    def divide(other, precision)
      raise Error.new(22012, "Division by zero") if other.zero?
      if special || other.special
        return self.class.new(0, 0, nil) if finite? && other.special != :nan
        sign = signum * other.signum
        value = special && other.finite? && !sign.zero? ? (sign.positive? ? :infinity : :negative_infinity) : :nan
        return self.class.new(0, 0, value)
      end

      target_scale = scale - self.precision + other.precision - other.scale + precision
      power = other.precision - self.precision + precision
      numerator, denominator = unscaled.abs, other.unscaled.abs
      power >= 0 ? numerator *= 10**power : denominator *= 10**-power
      integer, remainder = numerator.divmod(denominator)
      integer += 1 if remainder * 2 > denominator
      integer = -integer if signum * other.signum < 0
      excess = integer.abs.to_s.length - precision
      if excess.positive?
        divisor = 10**excess
        rounded, rest = integer.abs.divmod(divisor)
        rounded += 1 if rest * 2 >= divisor
        integer = integer.negative? ? -rounded : rounded
        target_scale -= excess
      end
      self.class.new(integer, target_scale, nil)
    end

    def remainder(other)
      raise Error.new(22012, "Division by zero") if other.zero?
      return self.class.new(0, 0, :nan) if special || other.special == :nan
      return self if other.special

      if scale <= other.scale
        remainder = (unscaled.abs * 10.pow(other.scale - scale, other.unscaled.abs)) % other.unscaled.abs
        self.class.new(unscaled.negative? ? -remainder : remainder, other.scale, nil)
      elsif other.precision + scale - other.scale > precision
        self
      else
        self.class.new(unscaled.remainder(other.unscaled * 10**(scale - other.scale)), scale, nil)
      end
    end

    def round(precision)
      return self if special || self.precision <= precision

      divisor = 10**(self.precision - precision)
      integer, rest = unscaled.abs.divmod(divisor)
      integer += 1 if rest * 2 >= divisor
      self.class.new(unscaled.negative? ? -integer : integer, scale - self.precision + precision, nil)
    end

    def quantize(target_scale, mode)
      raise Error.new(22018, "Non-finite DECFLOAT cannot be rounded") unless finite?
      return self if target_scale >= scale || zero?

      places = scale - target_scale
      if places > precision
        integer, remainder, half = 0, unscaled.abs, false
      else
        divisor = 10**places
        integer, remainder = unscaled.abs.divmod(divisor)
        half = remainder * 2 >= divisor
      end
      increment = case mode
      when :floor then unscaled.negative? && !remainder.zero?
      when :ceiling then unscaled.positive? && !remainder.zero?
      when :half_up then half
      when :down then false
      end
      integer += 1 if increment
      self.class.new(unscaled.negative? ? -integer : integer, target_scale, nil)
    end

    def json_text
      raise Error.new(22018, "Non-finite DECFLOAT cannot convert to JSON") if special

      JsonDocument.number("#{unscaled}e#{-scale}").value
    end

    def to_s
      return {infinity: 'Infinity', negative_infinity: '-Infinity', nan: 'NaN'}.fetch(special) if special

      json_text.sub(/E(?=\d)/, 'E+')
    end

    def to_d = BigDecimal(special ? to_s : "#{unscaled}e#{-scale}")
    def sql = "CAST(#{special ? "'#{to_s}'" : to_s} AS DECFLOAT(#{precision}))"

    def negate
      opposite = {infinity: :negative_infinity, negative_infinity: :infinity, nan: :nan}[special]
      self.class.new(-unscaled, scale, opposite)
    end

    def <=>(other)
      other = self.class.convert(other)
      rank = ->(value) { {negative_infinity: 0, infinity: 2, nan: 3}.fetch(value.special, 1) }
      order = rank.call(self) <=> rank.call(other)
      order.zero? && !special ? to_d <=> other.to_d : order
    end
  end
end

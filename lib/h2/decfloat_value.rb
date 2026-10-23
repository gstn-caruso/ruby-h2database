# frozen_string_literal: true

module H2
  class DecfloatValue < Data.define(:unscaled, :scale, :special)
    def initialize(unscaled:, scale:, special:)
      unless special
        if unscaled.zero?
          scale = 0
        else
          while (unscaled % 10).zero?
            unscaled /= 10
            scale -= 1
          end
        end
      end
      super
    end

    def self.parse(text)
      text = text.encode(Encoding::UTF_8).sub(/\A[\x00-\x20]+/, '').sub(/[\x00-\x20]+\z/, '')
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

    def round(precision)
      return self if special || self.precision <= precision

      divisor = 10**(self.precision - precision)
      integer, rest = unscaled.abs.divmod(divisor)
      integer += 1 if rest * 2 >= divisor
      self.class.new(unscaled.negative? ? -integer : integer, scale - self.precision + precision, nil)
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
    def sql = "CAST(#{special ? "'#{to_s}'" : to_s} AS DECFLOAT)"

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

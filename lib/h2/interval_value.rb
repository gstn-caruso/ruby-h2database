# frozen_string_literal: true

require_relative "interval_units"

module H2
  class IntervalValue < Data.define(:qualifier, :negative, :leading, :remaining)
    include Comparable

    def initialize(qualifier:, negative:, leading:, remaining:)
      ordinal = IntervalUnits.ordinal(qualifier)
      unless [true, false].include?(negative) && leading.is_a?(Integer) && remaining.is_a?(Integer) &&
          (0..IntervalUnits::MAXIMUM).cover?(leading) && (0...IntervalUnits::BOUNDS[ordinal]).cover?(remaining)
        raise Error.new(90008, "Invalid interval components")
      end
      super(qualifier: qualifier.dup.freeze, negative: negative && (leading != 0 || remaining != 0), leading: leading, remaining: remaining)
    rescue ArgumentError
      raise Error.new(90008, "Invalid interval qualifier")
    end

    def ordinal
      IntervalUnits.ordinal(qualifier)
    end

    def year_month?
      IntervalUnits.year_month?(ordinal)
    end

    def absolute
      IntervalUnits.absolute(ordinal, negative, leading, remaining)
    end

    def self.from_absolute(qualifier, value)
      ordinal = IntervalUnits.ordinal(qualifier)
      leading, rest = value.abs.divmod(IntervalUnits::LEADING[ordinal])
      raise Error.new(22003, "Interval is outside its leading field range") if leading > IntervalUnits::MAXIMUM

      unit = IntervalUnits::REMAINING[ordinal]
      new(qualifier, value.negative?, leading, unit.zero? ? 0 : rest / unit)
    end

    def self.parse(qualifier, text, negative: false)
      ordinal = IntervalUnits.ordinal(qualifier)
      pattern = case qualifier
      when "YEAR", "MONTH", "DAY", "HOUR", "MINUTE" then /\A([+-]?\d+)\z/
      when "SECOND" then /\A([+-]?\d+)(?:\.(\d+))?\z/
      when "YEAR TO MONTH" then /\A([+-]?\d+)(?:-(\d+))?\z/
      when "DAY TO HOUR" then /\A([+-]?\d+)(?: (\d+))?\z/
      when "DAY TO MINUTE" then /\A([+-]?\d+)(?: (\d+)(?::(\d+))?)?\z/
      when "DAY TO SECOND" then /\A([+-]?\d+)(?: (\d+)(?::(\d+)(?::(\d+)(?:\.(\d+))?)?)?)?\z/
      when "HOUR TO MINUTE" then /\A([+-]?\d+)(?::(\d+))?\z/
      when "HOUR TO SECOND" then /\A([+-]?\d+)(?::(\d+)(?::(\d+)(?:\.(\d+))?)?)?\z/
      when "MINUTE TO SECOND" then /\A([+-]?\d+)(?::(\d+)(?:\.(\d+))?)?\z/
      end
      match = pattern.match(text)
      raise Error.new(22007, "Invalid INTERVAL text") unless match

      sign = negative ^ match[1].start_with?("-")
      fields = match.captures.drop(1)
      fraction = IntervalUnits.seconds?(ordinal) ? fields.pop : nil
      nanos = fraction.to_s[0, 9].ljust(9, "0").to_i
      leading = Integer(match[1], 10).abs
      fields = fields.map { it ? Integer(it, 10) : 0 }
      if qualifier == "SECOND"
        rest = nanos
      elsif qualifier == "YEAR TO MONTH"
        rest = fields.fetch(0)
      else
        first = IntervalUnits::FIRST[ordinal]
        units = [IntervalUnits::DAY, IntervalUnits::HOUR, IntervalUnits::MINUTE, IntervalUnits::SECOND]
        fields.each_with_index do |field, index|
          maximum = first.zero? && index.zero? ? 23 : 59
          raise Error.new(22007, "Invalid interval subfield") if field > maximum
        end
        absolute = fields.each_with_index.sum { |field, index| field * units.fetch(first + index + 1) } + nanos
        unit = IntervalUnits::REMAINING[ordinal]
        rest = unit.zero? ? 0 : absolute / unit
      end
      new(qualifier, sign, leading, rest)
    rescue Error, ArgumentError, TypeError, EncodingError
      raise Error.new(22007, "Invalid INTERVAL #{text.inspect}")
    end

    def round(type)
      ordinal = self.ordinal
      value = self
      if IntervalUnits.seconds?(ordinal) && type.scale < 9
        unit = 10**(9 - type.scale)
        rest = (remaining + unit / 2) / unit * unit
        bound = IntervalUnits::BOUNDS[ordinal]
        rest = bound - unit if leading == IntervalUnits::MAXIMUM && rest >= bound
        carry, rest = rest.divmod(bound)
        value = self.class.new(qualifier, negative, leading + carry, rest)
      end
      if type.precision && value.leading >= 10**type.precision
        raise Error.new(22001, "Interval exceeds its leading field precision")
      end
      value
    end

    def to_i
      bound = IntervalUnits::BOUNDS[ordinal]
      integer = leading + (bound > 1 && remaining >= bound / 2 ? 1 : 0)
      negative ? -integer : integer
    end

    def to_d
      bound = IntervalUnits::BOUNDS[ordinal]
      decimal = BigDecimal(leading.to_s)
      decimal += (BigDecimal(remaining.to_s) / bound).round(bound.to_s.length, BigDecimal::ROUND_HALF_DOWN) if remaining != 0
      negative ? -decimal : decimal
    end

    def negate
      self.class.new(qualifier, !negative, leading, remaining)
    end

    def extract(field)
      ordinal = self.ordinal
      first, last = IntervalUnits::FIRST[ordinal], IntervalUnits::LAST[ordinal]
      rest = remaining * IntervalUnits::REMAINING[ordinal]
      if field == "EPOCH"
        if year_month?
          years, months = absolute.abs.divmod(12)
          seconds = BigDecimal((years * 31_557_600 + months * 2_592_000).to_s)
          return negative ? -seconds : seconds
        end
        return BigDecimal(absolute.to_s) / IntervalUnits::SECOND
      end
      value = case field
      when "YEAR" then year_month? && first.zero? ? leading : 0
      when "MONTH" then qualifier == "MONTH" ? leading : (qualifier == "YEAR TO MONTH" ? remaining : 0)
      when "DAY", "DAY_OF_YEAR" then !year_month? && first.zero? ? leading : 0
      when "HOUR" then !year_month? && first == 1 ? leading : (!year_month? && first.zero? && last >= 1 ? rest / IntervalUnits::HOUR : 0)
      when "MINUTE" then !year_month? && first == 2 ? leading : (!year_month? && first < 2 && last >= 2 ? rest / IntervalUnits::MINUTE % 60 : 0)
      when "SECOND", "MILLISECOND", "MICROSECOND", "NANOSECOND"
        nanos = if qualifier == "SECOND"
          IntervalUnits.wrap(leading * IntervalUnits::SECOND + remaining)
        elsif IntervalUnits.seconds?(ordinal)
          remaining % IntervalUnits::MINUTE
        else 0
        end
        nanos = IntervalUnits.wrap(-nanos) if negative
        value = case field
        when "SECOND" then IntervalUnits.divide(nanos, IntervalUnits::SECOND)
        when "MILLISECOND" then IntervalUnits.divide(nanos, 1_000_000)
        when "MICROSECOND" then IntervalUnits.divide(nanos, 1000)
        else nanos
        end
        modulus = {"MILLISECOND" => 1000, "MICROSECOND" => 1_000_000, "NANOSECOND" => IntervalUnits::SECOND}[field]
        value -= IntervalUnits.divide(value, modulus) * modulus if modulus
        return IntervalUnits.wrap(value, 32)
      else raise Error.new(50100, "EXTRACT #{field} is unsupported for INTERVAL")
      end
      IntervalUnits.wrap(negative ? -value : value, 32)
    end

    def to_s
      ordinal = self.ordinal
      text = leading.to_s
      if qualifier == "YEAR TO MONTH"
        text += "-#{remaining}"
      elsif ordinal > 6
        units = [IntervalUnits::DAY, IntervalUnits::HOUR, IntervalUnits::MINUTE, IntervalUnits::SECOND]
        absolute = remaining * IntervalUnits::REMAINING[ordinal]
        parts = ((IntervalUnits::FIRST[ordinal] + 1)..IntervalUnits::LAST[ordinal]).map do |index|
          field, absolute = absolute.divmod(units.fetch(index))
          field.to_s.rjust(2, "0")
        end
        text += (IntervalUnits::FIRST[ordinal].zero? ? " " : ":") + parts.join(":")
      end
      if IntervalUnits.seconds?(ordinal)
        fraction = remaining % IntervalUnits::SECOND
        text += ".#{fraction.to_s.rjust(9, '0').sub(/0+\z/, '')}" unless fraction.zero?
      end
      "INTERVAL '#{negative ? '-' : ''}#{text}' #{qualifier}"
    end

    def <=>(other)
      return unless other.is_a?(IntervalValue)
      raise Error.new(90110, "Incompatible interval families") unless year_month? == other.year_month?

      absolute <=> other.absolute
    end

    def ==(other)
      eql?(other)
    end
  end
end

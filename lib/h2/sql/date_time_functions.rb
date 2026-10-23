# frozen_string_literal: true

module H2
  module SQL
    module DateTimeFunctions
      NAMES = %w[DATEADD DATEDIFF].freeze
      ALIASES = {"TIMESTAMPADD" => "DATEADD", "TIMESTAMPDIFF" => "DATEDIFF"}.freeze
      FIELD_GROUPS = [
        %w[YEAR YY YYYY SQL_TSI_YEAR], %w[MONTH M MM SQL_TSI_MONTH], %w[DAY D DD SQL_TSI_DAY],
        %w[HOUR HH SQL_TSI_HOUR], %w[MINUTE MI N SQL_TSI_MINUTE], %w[SECOND S SS SQL_TSI_SECOND],
        %w[MILLISECOND MILLISECONDS MS], %w[MICROSECOND MICROSECONDS MCS], %w[NANOSECOND NS],
        %w[DAY_OF_YEAR DAYOFYEAR DY DOY], %w[ISO_DAY_OF_WEEK ISODOW], %w[ISO_WEEK],
        %w[ISO_WEEK_YEAR ISO_YEAR ISOYEAR], %w[DAY_OF_WEEK DAYOFWEEK], %w[WEEK WK WW SQL_TSI_WEEK],
        %w[WEEK_YEAR], %w[MILLENNIUM], %w[CENTURY], %w[DECADE], %w[QUARTER], %w[EPOCH], %w[DOW],
        %w[TIMEZONE_HOUR], %w[TIMEZONE_MINUTE], %w[TIMEZONE_SECOND]
      ].map(&:freeze).freeze
      FIELDS = FIELD_GROUPS.flat_map { |names| names.map { [it, names.first] } }.to_h.freeze
      NANOS = {"HOUR" => 3600 * Temporal::SECOND, "MINUTE" => 60 * Temporal::SECOND,
        "SECOND" => Temporal::SECOND, "EPOCH" => Temporal::SECOND,
        "MILLISECOND" => 1_000_000, "MICROSECOND" => 1000, "NANOSECOND" => 1}.freeze
      DAYS = %w[DAY DAY_OF_YEAR DAY_OF_WEEK DOW ISO_DAY_OF_WEEK].freeze
      YEARS = {"YEAR" => 1, "DECADE" => 10, "CENTURY" => 100, "MILLENNIUM" => 1000}.freeze
      module_function

      def field(name)
        FIELDS.fetch(name.upcase) { raise Error.new(90008, "Invalid date-time field #{name}") }
      end

      def type(name, field, argument)
        return Type.new("BIGINT", 64, 0) if name == "DATEDIFF"
        return argument unless Temporal::NAMES.include?(argument.name)

        result = argument.name == "DATE" && NANOS.key?(field) ? "TIMESTAMP" : argument.name
        Temporal.type(result, 9)
      end

      def evaluate(name, field, first, second, context: nil)
        return nil if first.nil? || second.nil?

        name == "DATEADD" ? add(field, count(first), second, context: context) : difference(field, first, second, context: context)
      end

      def count(value)
        if value.is_a?(String) && !BinaryString.binary?(value) && !value.strip.match?(/\A[+-]?\d+\z/)
          raise Error.new(22018, "DATEADD count is not an integer string")
        end
        if value.is_a?(Float)
          return 0 if value.nan?
          unless value.finite? && value >= -9_223_372_036_854_775_808 && value <= 9_223_372_036_854_775_808
            raise Error.new(22003, "DATEADD count is outside BIGINT range")
          end
          rounded = value.floor + (value - value.floor >= 0.5 ? 1 : 0)
          return [rounded, 9_223_372_036_854_775_807].min
        elsif value.is_a?(BigDecimal) && !Type::INTEGER_LIMITS.fetch("BIGINT").cover?(value)
          raise Error.new(22003, "DATEADD count is outside BIGINT range")
        end
        Type.new("BIGINT", 19, 0).convert(value)
      end

      def components(value, context: nil)
        case value
        when DateValue then [value, 0]
        when TimeValue, TimeTimeZoneValue then [DateValue.new(1970, 1, 1), value.nanos]
        when TimestampValue, TimestampTimeZoneValue then [value.date, value.time.nanos]
        else
          timestamp = Temporal.convert(value, "TIMESTAMP", context: context)
          [timestamp.date, timestamp.time.nanos]
        end
      end

      def wrap(value, bits = 64)
        (value + 2**(bits - 1)) % 2**bits - 2**(bits - 1)
      end

      def add(field, count, value, context: nil)
        unless %w[MILLISECOND MICROSECOND NANOSECOND].include?(field) || Type::INTEGER_LIMITS.fetch("INTEGER").cover?(count)
          raise Error.new(90008, "DATEADD count is outside INTEGER range")
        end
        date, nanos = components(value, context: context)
        if field.start_with?("TIMEZONE_")
          raise Error.new(50100, "DATEADD #{field} requires a zoned value") unless Temporal.zoned?(value)

          unit = {"TIMEZONE_HOUR" => 3600, "TIMEZONE_MINUTE" => 60, "TIMEZONE_SECOND" => 1}.fetch(field)
          offset = value.offset_seconds + count * unit
          raise Error.new(50000, "Time zone offset exceeds 18 hours") unless (-64_800..64_800).cover?(offset)

          return value.with(offset_seconds: offset)
        end
        if YEARS.key?(field) || %w[MONTH QUARTER].include?(field)
          invalid_time(field) if Temporal.time?(value)
          year, month = date.year, date.month
          if YEARS.key?(field)
            year += count * YEARS.fetch(field)
          else
            year_delta, month = (month - 1 + count * (field == "QUARTER" ? 3 : 1)).divmod(12)
            year += year_delta
            month += 1
          end
          year = wrap(year, 32)
          date = DateValue.new(year, month, [date.day, DateValue.days_in_month(year, month)].min)
        elsif DAYS.include?(field) || %w[WEEK ISO_WEEK].include?(field)
          invalid_time(field) if Temporal.time?(value)
          date = date.add_days(count * (%w[WEEK ISO_WEEK].include?(field) ? 7 : 1))
        elsif NANOS.key?(field)
          nanos = wrap(nanos + wrap(count * NANOS.fetch(field)))
          if nanos >= Temporal::DAY || nanos.negative?
            days = if nanos.negative?
              dividend = wrap(nanos - Temporal::DAY + 1)
              dividend.negative? ? -((-dividend) / Temporal::DAY) : dividend / Temporal::DAY
            else
              nanos / Temporal::DAY
            end
            nanos = wrap(nanos - wrap(days * Temporal::DAY))
          else
            days = 0
          end
          date = date.add_days(days)
          unless (0...Temporal::DAY).cover?(nanos)
            raise Error.new(Temporal.time?(value) ? 22007 : 50000, "DATEADD time is outside its day")
          end
          return TimestampValue.new(date, TimeValue.new(nanos)) if value.is_a?(DateValue)
        else
          raise Error.new(50100, "DATEADD #{field} has not been ported")
        end
        Temporal.with_components(value, date, nanos)
      rescue Error => error
        raise unless error.code == 22007 && date && !Temporal.time?(value)

        raise Error.new(50000, "DATEADD result is outside the supported year range")
      end

      def invalid_time(field)
        raise Error.new(90008, "DATEADD #{field} is not valid for TIME")
      end

      def difference(field, first, second, context: nil)
        if field.start_with?("TIMEZONE_")
          unit = {"TIMEZONE_HOUR" => 3600, "TIMEZONE_MINUTE" => 60, "TIMEZONE_SECOND" => 1}.fetch(field)
          offsets = [first, second].map { IntervalUnits.divide(Temporal.offset(it, context), unit) }
          return offsets[1] - offsets[0]
        end
        a, a_nanos = components(first, context: context)
        b, b_nanos = components(second, context: context)
        days = b.absolute_day - a.absolute_day
        result = if NANOS.key?(field)
          unit = NANOS.fetch(field)
          days * (Temporal::DAY / unit) + b_nanos / unit - a_nanos / unit
        elsif DAYS.include?(field)
          days
        else
          case field
          when "ISO_WEEK", "WEEK"
            offset = field == "ISO_WEEK" ? 3 : 4
            (b.absolute_day + offset).div(7) - (a.absolute_day + offset).div(7)
          when "YEAR" then b.year - a.year
          when "MONTH" then wrap((b.year - a.year) * 12 + b.month - a.month, 32)
          when "QUARTER" then wrap((b.year - a.year) * 4 + (b.month - 1) / 3 - (a.month - 1) / 3, 32)
          when "DECADE" then b.year.div(10) - a.year.div(10)
          when "CENTURY", "MILLENNIUM"
            divisor = field == "CENTURY" ? 100 : 1000
            period(b.year, divisor) - period(a.year, divisor)
          else raise Error.new(50100, "DATEDIFF #{field} has not been ported")
          end
        end
        wrap(result)
      end

      def period(year, divisor)
        year.positive? ? (year + divisor - 1) / divisor : -((-year) / divisor)
      end
    end
  end
end

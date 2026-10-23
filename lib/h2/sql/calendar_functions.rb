# frozen_string_literal: true

module H2
  module SQL
    module CalendarFunctions
      NAMES = %w[DATE_TRUNC LAST_DAY EXTRACT].freeze
      FIELD_FUNCTIONS = {
        "DAY" => "DAY", "DAY_OF_MONTH" => "DAY", "DAYOFMONTH" => "DAY",
        "DAY_OF_WEEK" => "DAY_OF_WEEK", "DAYOFWEEK" => "DAY_OF_WEEK",
        "DAY_OF_YEAR" => "DAY_OF_YEAR", "DAYOFYEAR" => "DAY_OF_YEAR",
        "HOUR" => "HOUR", "MINUTE" => "MINUTE", "SECOND" => "SECOND", "MONTH" => "MONTH",
        "YEAR" => "YEAR", "QUARTER" => "QUARTER", "WEEK" => "WEEK",
        "ISO_DAY_OF_WEEK" => "ISO_DAY_OF_WEEK", "ISO_WEEK" => "ISO_WEEK", "ISO_YEAR" => "ISO_WEEK_YEAR"
      }.freeze
      module_function

      def type(name, field, argument)
        return Temporal.type("DATE") if name == "LAST_DAY"
        return field == "EPOCH" ? Type.new("NUMERIC", 28, 9) : Type.new("INTEGER", 32, 0) if name == "EXTRACT"
        unless Temporal::NAMES.include?(argument.name)
          raise Error.new(90008, "DATE_TRUNC requires a datetime argument")
        end
        argument
      end

      def constant_type(name, field, value, type)
        return type if value.nil?
        return Temporal.type(Temporal.name(value), 9) if name == "DATE_TRUNC"
        if name == "EXTRACT" && field == "EPOCH"
          scale = [value.scale, 0].max
          precision = (value * 10**scale).to_i.abs.to_s.length
          return Type.new("NUMERIC", precision, scale)
        end
        type
      end

      def evaluate(name, *values, context: nil)
        return nil if values.any?(&:nil?)

        case name
        when "DATE_TRUNC" then truncate(*values)
        when "LAST_DAY" then last_day(values.first, context: context)
        when "EXTRACT" then extract(*values, context: context)
        end
      end

      def last_day(value, context: nil)
        date = case value
        when DateValue then value
        when TimestampValue, TimestampTimeZoneValue then value.date
        else
          text = value.is_a?(BigDecimal) ? value.to_s("F") : BinaryString.text(value)
          Temporal.parse("TIMESTAMP WITH TIME ZONE", text, context: context).date
        end
        DateValue.new(date.year, date.month, DateValue.days_in_month(date.year, date.month))
      rescue Error => error
        raise if error.code == 50100

        raise Error.new(50000, "LAST_DAY cannot parse the datetime value")
      end

      def truncate(field, value)
        date, nanos = DateTimeFunctions.components(value)
        if %w[MICROSECOND MILLISECOND SECOND MINUTE HOUR].include?(field)
          unit = DateTimeFunctions::NANOS.fetch(field)
          nanos = nanos / unit * unit
        else
          date = case field
          when "DAY" then date
          when "ISO_WEEK", "WEEK"
            first = field == "ISO_WEEK" ? 1 : 7
            DateValue.from_days(date.absolute_day - weekday(date.absolute_day, first) + 1)
          when "ISO_WEEK_YEAR", "WEEK_YEAR"
            _year, start = week_year(date, iso: field == "ISO_WEEK_YEAR")
            DateValue.from_days(start)
          when "MONTH" then DateValue.new(date.year, date.month, 1)
          when "QUARTER" then DateValue.new(date.year, (date.month - 1) / 3 * 3 + 1, 1)
          when "YEAR" then DateValue.new(date.year, 1, 1)
          when "DECADE" then DateValue.new(date.year.div(10) * 10, 1, 1)
          when "CENTURY", "MILLENNIUM"
            unit = field == "CENTURY" ? 100 : 1000
            DateValue.new((DateTimeFunctions.period(date.year, unit) - 1) * unit + 1, 1, 1)
          else raise Error.new(50100, "DATE_TRUNC #{field} is unsupported")
          end
          nanos = 0 unless field == "WEEK_YEAR"
        end
        Temporal.with_components(value, date, nanos)
      rescue Error => error
        raise unless error.code == 22007

        raise Error.new(50000, "DATE_TRUNC is outside the supported year range")
      end

      def extract(field, value, context: nil)
        return value.extract(field) if value.is_a?(IntervalValue)

        date, nanos = DateTimeFunctions.components(value, context: context)
        case field
        when "YEAR" then date.year
        when "MONTH" then date.month
        when "DAY" then date.day
        when "DAY_OF_WEEK", "DOW" then weekday(date.absolute_day, 7)
        when "ISO_DAY_OF_WEEK" then weekday(date.absolute_day, 1)
        when "DAY_OF_YEAR" then date.absolute_day - DateValue.new(date.year, 1, 1).absolute_day + 1
        when "QUARTER" then (date.month + 2) / 3
        when "HOUR" then nanos / (3600 * Temporal::SECOND)
        when "MINUTE" then nanos / (60 * Temporal::SECOND) % 60
        when "SECOND" then nanos / Temporal::SECOND % 60
        when "MILLISECOND" then nanos % Temporal::SECOND / 1_000_000
        when "MICROSECOND" then nanos % Temporal::SECOND / 1000
        when "NANOSECOND" then nanos % Temporal::SECOND
        when "DECADE" then date.year.div(10)
        when "CENTURY", "MILLENNIUM" then DateTimeFunctions.period(date.year, field == "CENTURY" ? 100 : 1000)
        when "ISO_WEEK_YEAR", "WEEK_YEAR" then week_year(date, iso: field == "ISO_WEEK_YEAR").first
        when "ISO_WEEK", "WEEK"
          _year, start = week_year(date, iso: field == "ISO_WEEK")
          (date.absolute_day - start) / 7 + 1
        when "EPOCH" then BigDecimal(date.absolute_day.to_s) * 86_400 + BigDecimal(nanos.to_s) / Temporal::SECOND - (Temporal.zoned?(value) ? value.offset_seconds : 0)
        when "TIMEZONE_HOUR" then IntervalUnits.divide(Temporal.offset(value, context), 3600)
        when "TIMEZONE_MINUTE" then IntervalUnits.divide(Temporal.offset(value, context).remainder(3600), 60)
        when "TIMEZONE_SECOND" then Temporal.offset(value, context).remainder(60)
        else raise Error.new(50100, "EXTRACT #{field} requires the remaining time-zone support")
        end
      end

      def weekday(absolute_day, first)
        (absolute_day + 4 - first) % 7 + 1
      end

      def week_start(january, first, minimum)
        days = 8 - weekday(january, first)
        january + days - (days >= minimum ? 7 : 0)
      end

      def week_year(date, iso:)
        first, minimum = iso ? [1, 4] : [7, 1]
        year = date.year
        january = DateValue.new(year, 1, 1).absolute_day
        start = week_start(january, first, minimum)
        if date.absolute_day < start
          previous = january - 337 - DateValue.days_in_month(year - 1, 2)
          return [year - 1, week_start(previous, first, minimum)]
        end
        following = january + 337 + DateValue.days_in_month(year, 2)
        next_start = week_start(following, first, minimum)
        date.absolute_day >= next_start ? [year + 1, next_start] : [year, start]
      end
    end
  end
end

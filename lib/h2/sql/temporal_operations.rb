# frozen_string_literal: true

module H2
  module SQL
    module TemporalOperations
      FIELDS = %w[YEAR MONTH DAY DAY_OF_MONTH DAY_OF_WEEK DAY_OF_YEAR QUARTER HOUR MINUTE SECOND MILLISECOND MICROSECOND NANOSECOND].freeze
      FRACTIONAL = %w[NUMERIC REAL DOUBLE].freeze
      module_function

      def type(operator, left, right)
        a, b = left.name, right.name
        name = if operator == "+" && [a, b].all? { Temporal::NAMES.include?(it) }
          if [a, b].sort == %w[DATE TIME] || ([a, b].include?("TIMESTAMP") && [a, b].include?("TIME"))
            "TIMESTAMP"
          elsif a == "TIME" && b == "TIME"
            "TIME"
          end
        elsif ["+", "-"].include?(operator)
          temporal, number = Temporal::NAMES.include?(a) ? [left, right] : [right, left]
          if (operator == "+" || temporal.equal?(left)) && (number.name == "INTEGER" || FRACTIONAL.include?(number.name))
            if temporal.name == "TIME" && number.name == "INTEGER"
              raise Error.new(90008, "DATEADD DAY is not valid for TIME")
            end
            temporal.name == "DATE" && number.name != "INTEGER" ? "TIMESTAMP" : temporal.name
          end
        elsif operator == "*" && (a == "TIME" || b == "TIME")
          "TIME" if (Type::INTEGER_LIMITS.keys + FRACTIONAL).include?(a == "TIME" ? b : a)
        elsif operator == "/" && a == "TIME"
          "TIME" if (Type::INTEGER_LIMITS.keys + FRACTIONAL).include?(b)
        end
        raise Error.new(50100, "Temporal operation #{a} #{operator} #{b} has not been ported") unless name

        scale = [a, b].all? { Temporal::NAMES.include?(it) } ? [left.scale || 0, right.scale || 0].max : 9
        Temporal.type(name, scale)
      end

      def evaluate(operator, left, right, left_type, right_type)
        result_type = type(operator, left_type, right_type)
        left = Temporal.convert(left, left_type.name) if Temporal::NAMES.include?(left_type.name)
        right = Temporal.convert(right, right_type.name) if Temporal::NAMES.include?(right_type.name)
        if ["*", "/"].include?(operator)
          time, number = left.is_a?(TimeValue) ? [left, right] : [right, left]
          factor = Float(number)
          value = operator == "*" ? time.nanos * factor : time.nanos / factor
          value = 0 if value.nan?
          return TimeValue.new(value.to_i)
        end
        if Temporal::NAMES.include?(left_type.name) && Temporal::NAMES.include?(right_type.name)
          if left.is_a?(TimeValue) && right.is_a?(TimeValue)
            return TimeValue.new((left.nanos + right.nanos) % Temporal::DAY)
          end
          date_time, time = left.is_a?(TimeValue) ? [right, left] : [left, right]
          timestamp = Temporal.convert(date_time, "TIMESTAMP")
          days, nanos = (timestamp.time.nanos + time.nanos).divmod(Temporal::DAY)
          return TimestampValue.new(timestamp.date.add_days(days), TimeValue.new(nanos))
        end
        temporal, number, number_type = Temporal.value?(left) ? [left, right, right_type] : [right, left, left_type]
        sign = operator == "-" ? -1 : 1
        if number_type.name == "INTEGER"
          number = number_type.convert(number)
          return temporal.add_days(sign * number) if temporal.is_a?(DateValue)

          return TimestampValue.new(temporal.date.add_days(sign * number), temporal.time)
        end
        seconds = (BigDecimal(number.to_s) * 86_400).round(0, BigDecimal::ROUND_HALF_UP).to_i * sign
        if result_type.name == "TIME"
          return TimeValue.new((temporal.nanos + seconds * Temporal::SECOND) % Temporal::DAY)
        end
        timestamp = Temporal.convert(temporal, "TIMESTAMP")
        days, nanos = (timestamp.time.nanos + seconds * Temporal::SECOND).divmod(Temporal::DAY)
        TimestampValue.new(timestamp.date.add_days(days), TimeValue.new(nanos))
      rescue FloatDomainError, ArgumentError, TypeError
        raise Error.new(22007, "Invalid temporal arithmetic result")
      end

      def extract(field, value)
        raise Error.new(90008, "Unsupported date field #{field}") unless FIELDS.include?(field)

        value = TimestampValue.parse(value.strip) if value.is_a?(String) && !BinaryString.binary?(value)
        date = case value
        when DateValue then value
        when TimestampValue then value.date
        when TimeValue then DateValue.new(1970, 1, 1)
        else raise Error.new(22018, "Cannot extract a field from #{value.class}")
        end
        nanos = value.is_a?(TimeValue) ? value.nanos : (value.is_a?(TimestampValue) ? value.time.nanos : 0)
        case field
        when "YEAR" then date.year
        when "MONTH" then date.month
        when "DAY", "DAY_OF_MONTH" then date.day
        when "DAY_OF_WEEK" then (date.absolute_day + 4) % 7 + 1
        when "DAY_OF_YEAR" then date.absolute_day - DateValue.new(date.year, 1, 1).absolute_day + 1
        when "QUARTER" then (date.month + 2) / 3
        when "HOUR" then nanos / (3600 * Temporal::SECOND)
        when "MINUTE" then nanos / (60 * Temporal::SECOND) % 60
        when "SECOND" then nanos / Temporal::SECOND % 60
        when "MILLISECOND" then nanos % Temporal::SECOND / 1_000_000
        when "MICROSECOND" then nanos % Temporal::SECOND / 1000
        when "NANOSECOND" then nanos % Temporal::SECOND
        end
      end
    end
  end
end

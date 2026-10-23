# frozen_string_literal: true

module H2
  module SQL
    module TemporalOperations
      FRACTIONAL = %w[NUMERIC REAL DOUBLE].freeze
      module_function

      def type(operator, left, right)
        a, b = left.name, right.name
        name = if operator == "+" && [a, b].all? { Temporal::NAMES.include?(it) }
          higher, lower = [a, b].sort_by { Temporal::NAMES.index(it) }.reverse
          unless (higher == "TIME WITH TIME ZONE" && lower == higher) ||
              (higher == "TIMESTAMP WITH TIME ZONE" && lower == "TIME WITH TIME ZONE") || higher == "DATE"
            if lower == "DATE" && Temporal.time_type?(higher)
              higher == "TIME" ? "TIMESTAMP" : "TIMESTAMP WITH TIME ZONE"
            elsif higher == "TIMESTAMP" && lower == "TIME WITH TIME ZONE"
              "TIMESTAMP WITH TIME ZONE"
            else
              higher
            end
          end
        elsif ["+", "-"].include?(operator)
          temporal, number = Temporal::NAMES.include?(a) ? [left, right] : [right, left]
          if (operator == "+" || temporal.equal?(left)) && (number.name == "INTEGER" || FRACTIONAL.include?(number.name))
            if Temporal.time_type?(temporal.name) && operator == "-"
              raise Error.new(50100, "Numeric subtraction from TIME is not supported")
            end
            if Temporal.time_type?(temporal.name) && number.name == "INTEGER"
              raise Error.new(90008, "DATEADD DAY is not valid for TIME")
            end
            temporal.name == "DATE" && number.name != "INTEGER" ? "TIMESTAMP" : temporal.name
          end
        elsif operator == "*" && (a == "TIME" || b == "TIME")
          "TIME"
        elsif operator == "/" && a == "TIME"
          "TIME"
        end
        raise Error.new(50100, "Temporal operation #{a} #{operator} #{b} has not been ported") unless name

        scale = [a, b].all? { Temporal::NAMES.include?(it) } ? [left.scale || 0, right.scale || 0].max : 9
        Temporal.type(name, scale)
      end

      def evaluate(operator, left, right, left_type, right_type, context: nil)
        result_type = type(operator, left_type, right_type)
        left = Temporal.convert(left, left_type.name, context: context) if Temporal::NAMES.include?(left_type.name)
        right = Temporal.convert(right, right_type.name, context: context) if Temporal::NAMES.include?(right_type.name)
        if ["*", "/"].include?(operator)
          time, number = left.is_a?(TimeValue) ? [left, right] : [right, left]
          factor = Type.new("DOUBLE", 53, nil).convert(number)
          value = operator == "*" ? time.nanos * factor : time.nanos / factor
          value = 0 if value.nan?
          return TimeValue.new(value.to_i)
        end
        if Temporal::NAMES.include?(left_type.name) && Temporal::NAMES.include?(right_type.name)
          ordered = [[left, left_type], [right, right_type]].sort_by { Temporal::NAMES.index(it[1].name) }.reverse
          base, extra = ordered.map(&:first)
          if extra.is_a?(DateValue) && Temporal.time?(base)
            return Temporal.zoned?(base) ? TimestampTimeZoneValue.new(extra, base.time, base.offset_seconds) : TimestampValue.new(extra, base)
          end
          raise Error.new(50000, "Invalid datetime addition operands") unless Temporal.time?(extra)

          base = TimestampTimeZoneValue.new(base.date, base.time, extra.offset_seconds) if base.is_a?(TimestampValue) && extra.is_a?(TimeTimeZoneValue)
          date, nanos = DateTimeFunctions.components(base)
          days, nanos = (nanos + extra.nanos).divmod(Temporal::DAY)
          return Temporal.with_components(base, date.add_days(days), nanos)
        end
        temporal, number, number_type = Temporal.value?(left) ? [left, right, right_type] : [right, left, left_type]
        sign = operator == "-" ? -1 : 1
        if number_type.name == "INTEGER"
          number = number_type.convert(number)
          return temporal.add_days(sign * number) if temporal.is_a?(DateValue)

          return Temporal.with_components(temporal, temporal.date.add_days(sign * number), temporal.time.nanos)
        end
        seconds = (BigDecimal(number.to_s) * 86_400).round(0, BigDecimal::ROUND_HALF_UP).to_i * sign
        if Temporal.time_type?(result_type.name)
          return Temporal.with_components(temporal, DateValue.new(1970, 1, 1), (temporal.nanos + seconds * Temporal::SECOND) % Temporal::DAY)
        end
        timestamp = temporal.is_a?(TimestampTimeZoneValue) ? temporal : Temporal.convert(temporal, "TIMESTAMP", context: context)
        days, nanos = (timestamp.time.nanos + seconds * Temporal::SECOND).divmod(Temporal::DAY)
        Temporal.with_components(timestamp, timestamp.date.add_days(days), nanos)
      rescue FloatDomainError, ArgumentError, TypeError
        raise Error.new(22007, "Invalid temporal arithmetic result")
      end

    end
  end
end

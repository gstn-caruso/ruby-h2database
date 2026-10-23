# frozen_string_literal: true

module H2
  module SQL
    module IntervalOperations
      NUMERIC = Type::INTEGER_LIMITS.keys + %w[NUMERIC REAL DOUBLE]
      module_function

      def applicable?(operator, left, right)
        Intervals.name?(left.name) || Intervals.name?(right.name) ||
          (operator == "-" && Temporal::NAMES.include?(left.name) && Temporal::NAMES.include?(right.name))
      end

      def type(operator, left, right)
        a, b = left.name, right.name
        if Temporal::NAMES.include?(a) && Temporal::NAMES.include?(b) && operator == "-"
          qualifier = a == "TIME" && b == "TIME" ? "HOUR TO SECOND" : (a == "DATE" && b == "DATE" ? "DAY" : "DAY TO SECOND")
          return Intervals.type(qualifier, 18, 9)
        end
        if Intervals.name?(a) && Intervals.name?(b)
          ordinals = [a, b].map { IntervalUnits.ordinal(it.delete_prefix("INTERVAL ")) }
          if IntervalUnits.year_month?(ordinals[0]) == IntervalUnits.year_month?(ordinals[1])
            if %w[+ -].include?(operator)
              return Intervals.type(IntervalUnits::QUALIFIERS[IntervalUnits.common(ordinals)], 18, 9)
            elsif operator == "/"
              return IntervalUnits.year_month?(ordinals[0]) ? Type.new("NUMERIC", 60, 40) : Type.new("NUMERIC", 96, 64)
            end
          end
        elsif (Intervals.name?(a) && NUMERIC.include?(b) && %w[* /].include?(operator)) ||
            (NUMERIC.include?(a) && Intervals.name?(b) && operator == "*")
          return Intervals.name?(a) ? left : right
        elsif (%w[+ -].include?(operator) && Temporal::NAMES.include?(a) && Intervals.name?(b)) ||
            (operator == "+" && Intervals.name?(a) && Temporal::NAMES.include?(b))
          datetime, interval = Temporal::NAMES.include?(a) ? [left, right] : [right, left]
          if datetime.name != "TIME" || !IntervalUnits.year_month?(IntervalUnits.ordinal(Intervals.qualifier(interval)))
            return datetime
          end
        end
        raise Error.new(50100, "Unsupported interval operation #{a} #{operator} #{b}")
      end

      def evaluate(operator, left, right, left_type, right_type)
        result = type(operator, left_type, right_type)
        if Temporal::NAMES.include?(left_type.name) && Temporal::NAMES.include?(right_type.name)
          a_date, a_time = DateTimeFunctions.components(left)
          b_date, b_time = DateTimeFunctions.components(right)
          absolute = (a_date.absolute_day - b_date.absolute_day) * IntervalUnits::DAY + a_time - b_time
          return IntervalValue.from_absolute(Intervals.qualifier(result), absolute)
        end
        if Intervals.name?(left_type.name) && Intervals.name?(right_type.name)
          if operator == "/"
            raise Error.new(22012, "Interval division by zero") if right.absolute.zero?

            return decimal(Rational(left.absolute, right.absolute), result.scale)
          end
          absolute = left.absolute + (operator == "-" ? -right.absolute : right.absolute)
          return IntervalValue.from_absolute(Intervals.qualifier(result), absolute)
        end
        interval, value = left.is_a?(IntervalValue) ? [left, right] : [right, left]
        if Temporal.value?(value)
          return datetime(operator, value, interval)
        end
        factor = BigDecimal(value.to_s).to_r
        amount = if operator == "*"
          interval.absolute * factor
        else
          raise Error.new(50000, "Interval division by zero") if factor.zero?

          interval.absolute / factor
        end
        if operator == "/"
          denominator = amount.denominator
          [2, 5].each { |prime| denominator /= prime while denominator % prime == 0 }
          raise Error.new(50000, "Nonterminating interval division") unless denominator == 1
        end
        IntervalValue.from_absolute(interval.qualifier, amount.to_i)
      rescue FloatDomainError, ArgumentError, TypeError
        raise Error.new(22018, "Invalid numeric interval operand")
      end

      def decimal(rational, scale)
        value, remainder = (rational.numerator.abs * 10**scale).divmod(rational.denominator)
        value += 1 if remainder * 2 > rational.denominator
        value = -value if rational.negative?
        BigDecimal(value.to_s) / 10**scale
      end

      def datetime(operator, value, interval)
        amount = interval.absolute * (operator == "-" ? -1 : 1)
        if interval.year_month?
          return DateTimeFunctions.add("MONTH", IntervalUnits.wrap(amount), value)
        elsif value.is_a?(TimeValue)
          nanos = value.nanos + amount
          raise Error.new(22003, "TIME interval result is outside its day") unless (0...IntervalUnits::DAY).cover?(nanos)

          return TimeValue.new(nanos)
        elsif value.is_a?(DateValue)
          return value.add_days(IntervalUnits.divide(amount, IntervalUnits::DAY))
        end
        days, nanos = (value.time.nanos + amount).divmod(IntervalUnits::DAY)
        TimestampValue.new(value.date.add_days(days), TimeValue.new(nanos))
      end

      def forced_difference(type, left, right)
        qualifier = Intervals.qualifier(type)
        if IntervalUnits.year_month?(IntervalUnits.ordinal(qualifier)) && !(left.is_a?(TimeValue) && right.is_a?(TimeValue))
          if left.is_a?(TimeValue) || right.is_a?(TimeValue)
            raise Error.new(50100, "Year-month differences with TIME require the remaining session date context")
          end
          a, a_nanos = DateTimeFunctions.components(left)
          b, b_nanos = DateTimeFunctions.components(right)
          months = (a.year - b.year) * 12 + a.month - b.month
          comparison = [a.day, a_nanos] <=> [b.day, b_nanos]
          months -= 1 if months >= 0 && comparison.negative?
          months += 1 if months < 0 && comparison.positive?
          value = IntervalValue.from_absolute("MONTH", months)
        else
          a = Temporal.type(Temporal.name(left), 9)
          b = Temporal.type(Temporal.name(right), 9)
          value = evaluate("-", left, right, a, b)
        end
        Intervals.convert(value, qualifier).round(type)
      end

      def aggregate_type(name, type)
        qualifier = Intervals.qualifier(type)
        return Intervals.type(qualifier, 18, type.scale) if name == "SUM"

        ordinal = IntervalUnits.ordinal(qualifier)
        qualifier = if IntervalUnits.year_month?(ordinal)
          ordinal == 1 ? "MONTH" : "YEAR TO MONTH"
        else
          ["DAY TO SECOND", "HOUR TO SECOND", "MINUTE TO SECOND", "SECOND"][IntervalUnits::FIRST[ordinal]]
        end
        Intervals.type(qualifier, type.precision, 9)
      end
    end
  end
end

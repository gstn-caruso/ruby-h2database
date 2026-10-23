# frozen_string_literal: true

module H2
  module SQL
    module TimeZoneOperations
      module_function

      def type(argument)
        unless argument && (Temporal::NAMES - ["DATE"]).include?(argument.name)
          raise Error.new(42001, "AT TIME ZONE requires TIME or TIMESTAMP")
        end
        Temporal.type(Temporal.time_type?(argument.name) ? "TIME WITH TIME ZONE" : "TIMESTAMP WITH TIME ZONE", argument.scale)
      end

      def zone(value)
        return TimeZone.parse(value) if value.is_a?(String) && !BinaryString.binary?(value)
        raise Error.new(90008, "Invalid time zone NULL") if value.nil?

        interval = Intervals.convert(value, "HOUR TO SECOND")
        absolute = interval.absolute
        unless absolute.abs <= 64_800 * Temporal::SECOND && absolute % Temporal::SECOND == 0
          raise Error.new(90008, "Invalid time zone interval")
        end
        FixedTimeZone.new(absolute / Temporal::SECOND)
      end

      def evaluate(value, target, requested, context:, local: false)
        return nil if value.nil?

        converted = Temporal.convert(value, target.name, context: context)
        return nil if !local && requested.nil?
        return converted if local && !Temporal.zoned?(value)

        provider = local ? context.zone : zone(requested)
        if converted.is_a?(TimeTimeZoneValue)
          raise Error.new(90008, "TIME requires a fixed time zone offset") if !local && !provider.fixed?

          epoch = (local ? context.current_date.absolute_day * 86_400 : 0) + converted.epoch_nanos.div(Temporal::SECOND)
        else
          epoch = converted.epoch_nanos.div(Temporal::SECOND)
        end
        converted.at_offset(provider.offset_utc(epoch))
      rescue Error => error
        raise unless error.code == 22007

        raise Error.new(50000, "Time zone conversion is outside the supported year range")
      end
    end
  end
end

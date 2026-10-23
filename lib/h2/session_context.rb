# frozen_string_literal: true

module H2
  class SessionContext
    attr_reader :zone, :zone_generation, :zero_based_enums

    def initialize(zero_based_enums: false)
      @zero_based_enums = zero_based_enums
      @zone = TimeZone.default
      @zone_generation = 0
    end

    def start_statement
      @statement_time = Time.now
    end

    def finish_statement
      @statement_time = Time.now
    end

    def current_timestamp
      @current_timestamp ||= begin
        instant = @statement_time || Time.now
        TimestampTimeZoneValue.from_epoch(instant.to_i * Temporal::SECOND + instant.nsec, zone.offset_utc(instant.to_i))
      end
    end

    def current_date
      current_timestamp.date
    end

    def end_transaction
      @current_timestamp = nil
    end

    def zone=(value)
      return if @zone == value

      @zone = value
      @zone_generation += 1
      @current_timestamp = @current_timestamp.at_offset(zone.offset_utc(@current_timestamp.epoch_nanos.div(Temporal::SECOND))) if @current_timestamp
    end
  end
end

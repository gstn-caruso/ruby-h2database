# frozen_string_literal: true

require_relative "temporal_units"

module H2
  module Temporal
    SECOND = 1_000_000_000
    DAY = 86_400 * SECOND
    NAMES = ["DATE", "TIME", "TIME WITH TIME ZONE", "TIMESTAMP", "TIMESTAMP WITH TIME ZONE"].freeze
    module_function

    def value?(value)
      value.is_a?(DateValue) || value.is_a?(TimeValue) || value.is_a?(TimestampValue) || zoned?(value)
    end

    def zoned?(value)
      value.is_a?(TimeTimeZoneValue) || value.is_a?(TimestampTimeZoneValue)
    end

    def time?(value)
      value.is_a?(TimeValue) || value.is_a?(TimeTimeZoneValue)
    end

    def time_type?(name)
      name == "TIME" || name == "TIME WITH TIME ZONE"
    end

    def name(value)
      case value
      when DateValue then "DATE"
      when TimeValue then "TIME"
      when TimestampValue then "TIMESTAMP"
      when TimeTimeZoneValue then "TIME WITH TIME ZONE"
      when TimestampTimeZoneValue then "TIMESTAMP WITH TIME ZONE"
      end
    end

    def from_ruby(value)
      if value.is_a?(::Time)
        TimestampValue.new(DateValue.new(value.year, value.month, value.day),
          TimeValue.new(((value.hour * 60 + value.min) * 60 + value.sec) * SECOND + value.nsec))
      elsif defined?(::DateTime) && value.is_a?(::DateTime)
        TimestampValue.new(DateValue.new(value.year, value.month, value.day),
          TimeValue.new(((value.hour * 60 + value.min) * 60 + value.sec) * SECOND + (value.sec_fraction * SECOND).to_i))
      elsif defined?(::Date) && value.is_a?(::Date)
        DateValue.new(value.year, value.month, value.day)
      else
        value
      end
    end

    def parse(name, text, context: nil)
      raise Error.new(22007, "Invalid datetime text") unless text.is_a?(String)
      return DateValue.parse(text) if name == "DATE"

      timestamp = name.start_with?("TIMESTAMP")
      parts = timestamp ? text.split(/[ T]/, 2) : [nil, text]
      date = DateValue.parse(parts[0]) if timestamp
      clock = timestamp ? parts[1] : text
      clock ||= "00:00:00"
      zone = nil
      if clock.end_with?("Z")
        clock, zone = clock[0...-1], TimeZone.parse("Z")
      elsif (index = clock.index(/[+-]/, 1))
        identifier = clock[index..]
        identifier = identifier.split("[", 2).first if timestamp
        zone = TimeZone.parse(identifier)
        clock = clock[0...index].rstrip
      elsif (index = clock.index(" ", 1))
        zone = TimeZone.parse(clock[index + 1..])
        clock = clock[0...index]
      end
      raise Error.new(22007, "TIME requires a fixed time zone offset") if !timestamp && zone && !zone.fixed?

      time = TimeValue.parse(clock)
      if name.end_with?("WITH TIME ZONE")
        explicit = !zone.nil?
        zone ||= context&.zone || TimeZone.default
        offset = if timestamp
          zone.offset_utc(zone.epoch_local(date, time.nanos))
        elsif explicit
          zone.offset_utc(0)
        else
          context ? context.current_timestamp.offset_seconds : zone.offset_utc(Time.now.to_i)
        end
        return timestamp ? TimestampTimeZoneValue.new(date, time, offset) : TimeTimeZoneValue.new(time.nanos, offset)
      end
      if zone
        target = context&.zone || TimeZone.default
        if timestamp
          epoch = zone.epoch_local(date, time.nanos)
          local = epoch + target.offset_utc(epoch)
          date = DateValue.from_days(local.div(86_400))
          time = TimeValue.new(local % 86_400 * SECOND + time.nanos % SECOND)
        else
          offset = context ? context.current_timestamp.offset_seconds : target.offset_utc(Time.now.to_i)
          time = TimeValue.new((time.nanos + (offset - zone.offset_utc(0)) * SECOND) % DAY)
        end
      end
      timestamp ? TimestampValue.new(date, time) : time
    rescue Error => error
      raise if error.code == 50100

      raise Error.new(22007, "Invalid #{name} #{text.inspect}")
    rescue ArgumentError, EncodingError
      raise Error.new(22007, "Invalid #{name} text")
    end

    def type(name, scale = nil)
      return Type.new("DATE", 10, 0) if name == "DATE"

      scale ||= time_type?(name) ? 0 : 6
      precision = (time_type?(name) ? 8 : 19) + (name.end_with?("WITH TIME ZONE") ? 6 : 0) + (scale.zero? ? 0 : scale + 1)
      Type.new(name, precision, scale)
    end

    def convert(value, name, context: nil)
      value = from_ruby(value)
      return parse(name, value.strip, context: context) if value.is_a?(String) && !BinaryString.binary?(value)

      case name
      when "DATE"
        return value if value.is_a?(DateValue)
        return value.date if value.is_a?(TimestampValue)
        return local_timestamp(value, context).date if value.is_a?(TimestampTimeZoneValue)
      when "TIME"
        return value if value.is_a?(TimeValue)
        return value.time if value.is_a?(TimestampValue)
        if value.is_a?(TimestampTimeZoneValue)
          offset = session(context).zone.offset_utc(value.epoch_nanos.div(SECOND))
          return TimeValue.new((value.epoch_nanos + offset * SECOND) % DAY)
        end
        if value.is_a?(TimeTimeZoneValue)
          offset = session(context).current_timestamp.offset_seconds
          return TimeValue.new((value.nanos + (offset - value.offset_seconds) * SECOND) % DAY)
        end
      when "TIMESTAMP"
        return value if value.is_a?(TimestampValue)
        return TimestampValue.new(value, TimeValue.new(0)) if value.is_a?(DateValue)
        return TimestampValue.new(session_date(context), value) if value.is_a?(TimeValue)
        return local_timestamp(value, context) if value.is_a?(TimestampTimeZoneValue)
        return TimestampValue.new(session_date(context), convert(value, "TIME", context: context)) if value.is_a?(TimeTimeZoneValue)
      when "TIME WITH TIME ZONE"
        return value if value.is_a?(TimeTimeZoneValue)
        return TimeTimeZoneValue.new(value.time.nanos, value.offset_seconds) if value.is_a?(TimestampTimeZoneValue)
        return TimeTimeZoneValue.new(value.nanos, session(context).current_timestamp.offset_seconds) if value.is_a?(TimeValue)
        return TimeTimeZoneValue.new(value.time.nanos, session(context).zone.offset_local(value.date, value.time.nanos)) if value.is_a?(TimestampValue)
      when "TIMESTAMP WITH TIME ZONE"
        return value if value.is_a?(TimestampTimeZoneValue)
        if value.is_a?(TimeTimeZoneValue)
          return TimestampTimeZoneValue.new(session_date(context), value.time, value.offset_seconds)
        end
        timestamp = case value
        when DateValue then TimestampValue.new(value, TimeValue.new(0))
        when TimeValue then TimestampValue.new(session_date(context), value)
        when TimestampValue then value
        end
        if timestamp
          offset = session(context).zone.offset_local(timestamp.date, timestamp.time.nanos)
          return TimestampTimeZoneValue.new(timestamp.date, timestamp.time, offset)
        end
      end
      raise Error.new(22018, "Cannot convert #{value.class} to #{name}")
    end

    def session_date(context)
      session(context).current_date
    end

    def session(context)
      raise Error.new(50100, "Conversion requires a SQL session context") unless context

      context
    end

    def local_timestamp(value, context)
      offset = session(context).zone.offset_utc(value.epoch_nanos.div(SECOND))
      local = value.at_offset(offset)
      TimestampValue.new(local.date, local.time)
    rescue Error => error
      raise unless error.code == 22007

      raise Error.new(50000, "Local timestamp is outside the supported year range")
    end

    def common_name(names)
      return "TIMESTAMP WITH TIME ZONE" if names.include?("TIMESTAMP WITH TIME ZONE") ||
        (names.include?("TIME WITH TIME ZONE") && (names & %w[DATE TIMESTAMP]).any?)
      return "TIMESTAMP" if names.include?("DATE") && names.include?("TIME")

      (names & NAMES).max_by { NAMES.index(it) }
    end

    def with_components(value, date, nanos)
      case value
      when DateValue then date
      when TimeValue then TimeValue.new(nanos)
      when TimeTimeZoneValue then TimeTimeZoneValue.new(nanos, value.offset_seconds)
      when TimestampTimeZoneValue then TimestampTimeZoneValue.new(date, TimeValue.new(nanos), value.offset_seconds)
      else TimestampValue.new(date, TimeValue.new(nanos))
      end
    end

    def offset(value, context)
      return value.offset_seconds if zoned?(value)

      date, nanos = SQL::DateTimeFunctions.components(value, context: context)
      session(context).zone.offset_local(date, nanos)
    end

    def comparison_key(value)
      return [name(value), value.epoch_nanos] if zoned?(value)
      return value.values.map { comparison_key(it) } if value.is_a?(RowValue)

      value
    end

    def compare(left, right, context: nil)
      names = [name(left), name(right)].compact
      target = common_name(names)
      convert(left, target, context: context) <=> convert(right, target, context: context)
    end

    def round_nanos(nanos, scale, clamp: false)
      return nanos if scale >= 9

      unit = 10**(9 - scale)
      result = (nanos + unit / 2) / unit * unit
      clamp && result >= DAY ? DAY - unit : result
    end

    def reject_zone(text)
      if (match = /(?<=\d)(?:Z|[+-]\d[\d:]*(?:\[[^\]]+\])?| [A-Za-z][\w\/+:-]*)\z/.match(text))
        TimeValue.parse(text[0...match.begin(0)].rstrip)
        raise Error.new(22007, "Time zone requires temporal parsing with a session context")
      end
    end
  end

  class DateValue < Data.define(:year, :month, :day)
    include Comparable

    def initialize(year:, month:, day:)
      unless [year, month, day].all? { it.is_a?(Integer) } && (-1_000_000_000..1_000_000_000).cover?(year) &&
          (1..12).cover?(month) && (1..self.class.days_in_month(year, month)).cover?(day)
        raise Error.new(22007, "Invalid DATE components")
      end
      super
    end

    def self.days_in_month(year, month)
      return (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 29 : 28 if month == 2

      [4, 6, 9, 11].include?(month) ? 30 : 31
    end

    def self.parse(text)
      raise Error.new(22007, "Invalid DATE text") unless text.is_a?(String)

      text = text.delete_prefix("+")
      parts = if (match = /\A(-?\d+)-(\d+)-(\d+)\z/.match(text))
        match.captures
      elsif text.length >= 7 && text.match?(/\A-?\d+\z/)
        [text[0...-4], text[-4, 2], text[-2, 2]]
      end
      raise Error.new(22007, "Invalid DATE #{text.inspect}") unless parts

      new(*parts.map { Integer(it, 10) })
    rescue ArgumentError, EncodingError
      raise Error.new(22007, "Invalid DATE text")
    end

    def packed
      (year << 9) | (month << 5) | day
    end

    def self.from_packed(value)
      new(value >> 9, (value >> 5) & 15, value & 31)
    end

    def absolute_day
      TemporalUnits.absolute_day(year, month, day)
    end

    def self.from_days(days)
      era, part = (days + 719_468).divmod(146_097)
      y = (part - part / 1460 + part / 36_524 - part / 146_096) / 365
      day_of_year = part - (365 * y + y / 4 - y / 100)
      m = (5 * day_of_year + 2) / 153
      d = day_of_year - (153 * m + 2) / 5 + 1
      month = m + (m < 10 ? 3 : -9)
      new(era * 400 + y + (month <= 2 ? 1 : 0), month, d)
    end

    def add_days(count)
      self.class.from_days(absolute_day + count)
    rescue Error => error
      raise unless error.code == 22007

      raise Error.new(50000, "Date arithmetic is outside the supported year range")
    end

    def to_s
      y = year.abs.to_s.rjust(4, "0")
      "#{year.negative? ? '-' : ''}#{y}-#{month.to_s.rjust(2, '0')}-#{day.to_s.rjust(2, '0')}"
    end

    def <=>(other)
      packed <=> other.packed if other.is_a?(DateValue)
    end
  end

  class TimeValue < Data.define(:nanos)
    include Comparable

    def initialize(nanos:)
      unless nanos.is_a?(Integer) && (0...Temporal::DAY).cover?(nanos)
        raise Error.new(22007, "TIME is outside its day")
      end
      super
    end

    def self.parse(text)
      raise Error.new(22007, "Invalid TIME text") unless text.is_a?(String)

      Temporal.reject_zone(text)
      parts = if text.include?(":")
        /\A(\d+):(\d+)(?::(\d+)(?:\.(\d+))?)?\z/.match(text)
      elsif text.match?(/\A\d{6}(?:\.\d+)?\z/)
        /\A(\d{2})(\d{2})(\d{2})(?:\.(\d+))?\z/.match(text)
      elsif text.match?(/\A\d{4}\z/)
        /\A(\d{2})(\d{2})()()\z/.match(text)
      else
        /\A(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?\z/.match(text)
      end
      raise Error.new(22007, "Invalid TIME #{text.inspect}") unless parts

      hour, minute, second = parts.captures.first(3).map { it.nil? || it.empty? ? 0 : Integer(it, 10) }
      unless hour < 24 && minute < 60 && second < 60
        raise Error.new(22007, "Invalid TIME fields")
      end
      fraction = parts[4].to_s[0, 9].ljust(9, "0").to_i
      new(((hour * 60 + minute) * 60 + second) * Temporal::SECOND + fraction)
    rescue ArgumentError, EncodingError
      raise Error.new(22007, "Invalid TIME text")
    end

    def round(scale)
      self.class.new(Temporal.round_nanos(nanos, scale, clamp: true))
    end

    def to_s
      seconds, fraction = nanos.divmod(Temporal::SECOND)
      hour, remainder = seconds.divmod(3600)
      minute, second = remainder.divmod(60)
      text = [hour, minute, second].map { it.to_s.rjust(2, "0") }.join(":")
      text += ".#{fraction.to_s.rjust(9, '0').sub(/0+\z/, '')}" unless fraction.zero?
      text
    end

    def <=>(other)
      nanos <=> other.nanos if other.is_a?(TimeValue)
    end
  end

  class TimestampValue < Data.define(:date, :time)
    include Comparable

    def initialize(date:, time:)
      unless date.is_a?(DateValue) && time.is_a?(TimeValue)
        raise Error.new(22007, "TIMESTAMP requires a date and a time")
      end
      super
    end

    def self.parse(text)
      raise Error.new(22007, "Invalid TIMESTAMP text") unless text.is_a?(String)

      parts = text.split(/[ T]/, 2)
      new(DateValue.parse(parts[0]), parts.length == 1 ? TimeValue.new(0) : TimeValue.parse(parts[1]))
    end

    def round(scale)
      maximum = date.year == 1_000_000_000 && date.month == 12 && date.day == 31
      day, nanos = Temporal.round_nanos(time.nanos, scale, clamp: maximum).divmod(Temporal::DAY)
      self.class.new(date.add_days(day), TimeValue.new(nanos))
    end

    def to_s
      "#{date} #{time}"
    end

    def <=>(other)
      [date.packed, time.nanos] <=> [other.date.packed, other.time.nanos] if other.is_a?(TimestampValue)
    end
  end

  class TimeTimeZoneValue < Data.define(:nanos, :offset_seconds)
    include Comparable

    def initialize(nanos:, offset_seconds:)
      TimeValue.new(nanos)
      FixedTimeZone.new(offset_seconds)
      super
    end

    def self.parse(text, context: nil) = Temporal.parse("TIME WITH TIME ZONE", text, context: context)
    def time = TimeValue.new(nanos)
    def epoch_nanos = nanos - offset_seconds * Temporal::SECOND
    def round(scale) = self.class.new(time.round(scale).nanos, offset_seconds)
    def at_offset(offset) = self.class.new((nanos + (offset - offset_seconds) * Temporal::SECOND) % Temporal::DAY, offset)
    def to_s = "#{time}#{TimeZone.format(offset_seconds)}"
    def <=>(other) = (epoch_nanos <=> other.epoch_nanos if other.is_a?(TimeTimeZoneValue))
  end

  class TimestampTimeZoneValue < Data.define(:date, :time, :offset_seconds)
    include Comparable

    def initialize(date:, time:, offset_seconds:)
      TimestampValue.new(date, time)
      FixedTimeZone.new(offset_seconds)
      super
    end

    def self.parse(text, context: nil) = Temporal.parse("TIMESTAMP WITH TIME ZONE", text, context: context)
    def epoch_nanos = date.absolute_day * Temporal::DAY + time.nanos - offset_seconds * Temporal::SECOND

    def self.from_epoch(nanos, offset)
      day, clock = (nanos + offset * Temporal::SECOND).divmod(Temporal::DAY)
      new(DateValue.from_days(day), TimeValue.new(clock), offset)
    end

    def at_offset(offset) = self.class.from_epoch(epoch_nanos, offset)

    def round(scale)
      value = TimestampValue.new(date, time).round(scale)
      self.class.new(value.date, value.time, offset_seconds)
    end

    def to_s = "#{date} #{time}#{TimeZone.format(offset_seconds)}"
    def <=>(other) = (epoch_nanos <=> other.epoch_nanos if other.is_a?(TimestampTimeZoneValue))
  end
end

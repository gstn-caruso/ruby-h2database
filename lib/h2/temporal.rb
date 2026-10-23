# frozen_string_literal: true

module H2
  module Temporal
    SECOND = 1_000_000_000
    DAY = 86_400 * SECOND
    NAMES = %w[DATE TIME TIMESTAMP].freeze
    module_function

    def value?(value)
      value.is_a?(DateValue) || value.is_a?(TimeValue) || value.is_a?(TimestampValue)
    end

    def name(value)
      case value
      when DateValue then "DATE"
      when TimeValue then "TIME"
      when TimestampValue then "TIMESTAMP"
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

    def parse(name, text)
      {"DATE" => DateValue, "TIME" => TimeValue, "TIMESTAMP" => TimestampValue}.fetch(name).parse(text)
    end

    def type(name, scale = nil)
      return Type.new("DATE", 10, 0) if name == "DATE"

      scale ||= name == "TIME" ? 0 : 6
      precision = (name == "TIME" ? 8 : 19) + (scale.zero? ? 0 : scale + 1)
      Type.new(name, precision, scale)
    end

    def convert(value, name, context: nil)
      value = from_ruby(value)
      return parse(name, value.strip) if value.is_a?(String) && !BinaryString.binary?(value)

      case name
      when "DATE"
        return value if value.is_a?(DateValue)
        return value.date if value.is_a?(TimestampValue)
      when "TIME"
        return value if value.is_a?(TimeValue)
        return value.time if value.is_a?(TimestampValue)
      when "TIMESTAMP"
        return value if value.is_a?(TimestampValue)
        return TimestampValue.new(value, TimeValue.new(0)) if value.is_a?(DateValue)
        return TimestampValue.new(session_date(context), value) if value.is_a?(TimeValue)
      end
      raise Error.new(22018, "Cannot convert #{value.class} to #{name}")
    end

    def session_date(context)
      raise Error.new(50100, "Conversion requires a SQL session date context") unless context

      context.current_date
    end

    def compare(left, right, context: nil)
      names = [name(left), name(right)].compact
      target = names.include?("TIMESTAMP") ? "TIMESTAMP" : names.first
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
        raise Error.new(50100, "Time-zone parsing requires the remaining session time-zone support")
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
      y = year - (month <= 2 ? 1 : 0)
      era, part = y.divmod(400)
      m = month + (month > 2 ? -3 : 9)
      era * 146_097 + part * 365 + part / 4 - part / 100 + (153 * m + 2) / 5 + day - 1 - 719_468
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
end

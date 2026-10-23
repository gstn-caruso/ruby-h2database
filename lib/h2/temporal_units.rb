# frozen_string_literal: true

module H2
  module TemporalUnits
    module_function

    def absolute_day(year, month, day)
      y = year - (month <= 2 ? 1 : 0)
      era, part = y.divmod(400)
      m = month + (month > 2 ? -3 : 9)
      era * 146_097 + part * 365 + part / 4 - part / 100 + (153 * m + 2) / 5 + day - 1 - 719_468
    end

    def timestamp_zone_nanos(data)
      date, nanos, offset = data
      absolute_day(date >> 9, (date >> 5) & 15, date & 31) * 86_400_000_000_000 + nanos - offset * 1_000_000_000
    end
  end
end

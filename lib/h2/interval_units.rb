# frozen_string_literal: true

module H2
  module IntervalUnits
    SECOND = 1_000_000_000
    MINUTE = 60 * SECOND
    HOUR = 60 * MINUTE
    DAY = 24 * HOUR
    QUALIFIERS = ["YEAR", "MONTH", "DAY", "HOUR", "MINUTE", "SECOND", "YEAR TO MONTH",
      "DAY TO HOUR", "DAY TO MINUTE", "DAY TO SECOND", "HOUR TO MINUTE", "HOUR TO SECOND", "MINUTE TO SECOND"].freeze
    LEADING = [12, 1, DAY, HOUR, MINUTE, SECOND, 12, DAY, DAY, DAY, HOUR, HOUR, MINUTE].freeze
    REMAINING = [0, 0, 0, 0, 0, 1, 1, HOUR, MINUTE, 1, MINUTE, 1, 1].freeze
    BOUNDS = [1, 1, 1, 1, 1, SECOND, 12, 24, 1440, DAY, 60, HOUR, MINUTE].freeze
    FIRST = [0, 1, 0, 1, 2, 3, 0, 0, 0, 0, 1, 1, 2].freeze
    LAST = [0, 1, 0, 1, 2, 3, 1, 1, 2, 3, 2, 3, 3].freeze
    YEAR_MONTH = [0, 1, 6].freeze
    MAXIMUM = 999_999_999_999_999_999
    module_function

    def ordinal(qualifier)
      QUALIFIERS.index(qualifier) || raise(ArgumentError, "Unknown interval qualifier #{qualifier}")
    end

    def year_month?(ordinal)
      YEAR_MONTH.include?(ordinal)
    end

    def seconds?(ordinal)
      !year_month?(ordinal) && LAST.fetch(ordinal) == 3
    end

    def absolute(ordinal, negative, leading, remaining)
      value = leading * LEADING.fetch(ordinal) + remaining * REMAINING.fetch(ordinal)
      negative ? -value : value
    end

    def wrap(value, bits = 64)
      (value + 2**(bits - 1)) % 2**bits - 2**(bits - 1)
    end

    def divide(value, divisor)
      value.negative? ? -((-value) / divisor) : value / divisor
    end

    def common(ordinals)
      family = year_month?(ordinals.first)
      raise ArgumentError, "Incompatible interval families" unless ordinals.all? { year_month?(it) == family }

      first = ordinals.map { FIRST.fetch(it) }.min
      last = ordinals.map { LAST.fetch(it) }.max
      QUALIFIERS.each_index.find { year_month?(it) == family && FIRST[it] == first && LAST[it] == last }
    end
  end
end

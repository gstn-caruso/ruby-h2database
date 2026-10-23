# frozen_string_literal: true

module H2
  module TimeZone
    ROOT = "/usr/share/zoneinfo"
    SHORT_IDS = {"ACT" => "Australia/Darwin", "AET" => "Australia/Sydney", "AGT" => "America/Argentina/Buenos_Aires",
      "ART" => "Africa/Cairo", "AST" => "America/Anchorage", "BET" => "America/Sao_Paulo", "BST" => "Asia/Dhaka",
      "CAT" => "Africa/Harare", "CNT" => "America/St_Johns", "CST" => "America/Chicago", "CTT" => "Asia/Shanghai",
      "EAT" => "Africa/Addis_Ababa", "ECT" => "Europe/Paris", "IET" => "America/Indiana/Indianapolis", "IST" => "Asia/Kolkata",
      "JST" => "Asia/Tokyo", "MIT" => "Pacific/Apia", "NET" => "Asia/Yerevan", "NST" => "Pacific/Auckland",
      "PLT" => "Asia/Karachi", "PNT" => "America/Phoenix", "PRT" => "America/Puerto_Rico", "PST" => "America/Los_Angeles",
      "SST" => "Pacific/Guadalcanal", "VST" => "Asia/Ho_Chi_Minh", "EST" => "-05:00", "MST" => "-07:00", "HST" => "-10:00"}.freeze
    module_function

    def parse(name)
      raise Error.new(90008, "Invalid time zone") unless name.is_a?(String)

      name = SHORT_IDS.fetch(name, name)
      return FixedTimeZone.new(0) if %w[Z UTC GMT].include?(name)
      offset_text = name.sub(/\A(?:UTC|GMT)(?=[+-])/, "")
      if (match = /\A([+-]?)(\d{1,2})(?::(\d{1,2})(?::(\d{1,2}))?)?\z/.match(offset_text))
        offset = (match[2].to_i * 60 + match[3].to_i) * 60 + match[4].to_i
        return FixedTimeZone.new(match[1] == "-" ? -offset : offset)
      end
      unless name.match?(/\A[A-Za-z0-9_+.-]+(?:\/[A-Za-z0-9_+.-]+)*\z/) &&
          (name.split("/") & %w[. .. right posix]).empty?
        raise Error.new(90008, "Invalid time zone #{name.inspect}")
      end
      ZoneRules.new(File.binread(File.join(ROOT, name)), id: name)
    rescue SystemCallError, ArgumentError, EncodingError
      raise Error.new(90008, "Unknown time zone #{name.inspect}")
    end

    def default
      name = ENV["TZ"]
      zone = if name && !name.empty?
        parse(name.delete_prefix(":"))
      else
        ZoneRules.new(File.binread("/etc/localtime"), id: File.realpath("/etc/localtime").delete_prefix("#{ROOT}/"))
      end
      zone.is_a?(ZoneRules) && zone.constant_offset ? FixedTimeZone.new(zone.constant_offset) : zone
    rescue SystemCallError
      FixedTimeZone.new(Time.now.utc_offset)
    end

    def format(offset)
      hours, rest = offset.abs.divmod(3600)
      minutes, seconds = rest.divmod(60)
      text = "#{offset.negative? ? '-' : '+'}#{hours.to_s.rjust(2, '0')}"
      text += ":#{minutes.to_s.rjust(2, '0')}" unless rest.zero?
      text += ":#{seconds.to_s.rjust(2, '0')}" unless seconds.zero?
      text
    end
  end

  class FixedTimeZone < Data.define(:offset)
    def initialize(offset:)
      raise Error.new(90008, "Time zone offset exceeds 18 hours") unless offset.is_a?(Integer) && (-64_800..64_800).cover?(offset)

      super
    end

    def fixed? = true
    def offset_utc(_seconds) = offset
    def offset_local(_date, _nanos) = offset
    def epoch_local(date, nanos) = date.absolute_day * 86_400 + nanos / Temporal::SECOND - offset
  end

  class AnnualTimeZone
    NAME = '(?:[A-Za-z]{3,}|<[^>]+>)'
    OFFSET = '[+-]?\d+(?::\d+(?::\d+)?)?'
    attr_reader :offsets

    def initialize(text)
      match = /\A#{NAME}(#{OFFSET})(?:#{NAME}(#{OFFSET})?)?(?:,([^,]+),([^,]+))?\z/.match(text)
      raise Error.new(50100, "Unsupported time zone recurrence #{text.inspect}") unless match

      @standard = -seconds(match[1])
      @daylight = match[2] ? -seconds(match[2]) : @standard + 3600
      @start, @finish = match[3], match[4]
      @offsets = (@start ? [@standard, @daylight] : [@standard]).uniq.freeze
      freeze
    end

    def transitions(year)
      return [] unless @start

      [[transition(@start, year, @standard), @standard, @daylight],
        [transition(@finish, year, @daylight), @daylight, @standard]]
    end

    def offset_utc(epoch)
      return @standard unless @start

      year = DateValue.from_days(epoch.div(86_400)).year
      transitions = (year - 1..year + 1).flat_map { transitions(it) }.sort_by(&:first)
      transitions.reverse_each.find { it[0] <= epoch }.fetch(2)
    end

    private

    def seconds(text)
      negative = text.start_with?("-")
      fields = text.delete_prefix("-").delete_prefix("+").split(":").map { Integer(it, 10) }
      result = fields[0] * 3600 + fields.fetch(1, 0) * 60 + fields.fetch(2, 0)
      negative ? -result : result
    end

    def transition(rule, year, previous)
      day, clock = rule.split("/", 2)
      january = DateValue.new(year, 1, 1).absolute_day
      absolute = if (match = /\AM(\d+)\.(\d+)\.(\d+)\z/.match(day))
        month, week, weekday = match.captures.map(&:to_i)
        first = DateValue.new(year, month, 1)
        date = 1 + (weekday - (first.absolute_day + 4) % 7) % 7 + (week - 1) * 7
        date -= 7 if date > DateValue.days_in_month(year, month)
        first.absolute_day + date - 1
      elsif day.start_with?("J")
        ordinal = Integer(day[1..], 10)
        january + ordinal - 1 + (ordinal >= 60 && DateValue.days_in_month(year, 2) == 29 ? 1 : 0)
      else
        january + Integer(day, 10)
      end
      clock ||= "2"
      basis = if clock.end_with?("u", "g", "z")
        0
      elsif clock.end_with?("s")
        @standard
      else
        previous
      end
      absolute * 86_400 + seconds(clock.sub(/[wsugz]\z/, "")) - basis
    end
  end

  class ZoneRules
    PERIOD = 146_097 * 86_400
    attr_reader :id

    def initialize(bytes, id: nil)
      @id = id&.dup&.freeze
      counts = header(bytes, 0)
      size = 4
      start = 44
      unless bytes.getbyte(4).zero?
        start += block_size(counts, 4)
        counts = header(bytes, start)
        start += 44
        size = 8
      end
      _ut, _standard, leaps, time_count, type_count, _chars = counts
      raise Error.new(50100, "Leap-second time zone files are not supported") unless leaps.zero?

      finish = start + block_size(counts, size)
      raise Error.new(90008, "Truncated time zone data") if finish > bytes.bytesize

      @transitions = bytes.byteslice(start, time_count * size).unpack(size == 8 ? "q>*" : "l>*").freeze
      indices = bytes.byteslice(start + time_count * size, time_count).bytes
      @types = Array.new(type_count) { |i| bytes.byteslice(start + time_count * (size + 1) + i * 6, 4).unpack1("l>") }.freeze
      raise Error.new(90008, "Invalid time zone types") if @types.empty? || indices.any? { it >= type_count }

      @transition_offsets = indices.map { @types[it] }.freeze
      footer = size == 8 ? bytes.byteslice(finish..).to_s.split("\n")[1] : nil
      @annual = AnnualTimeZone.new(footer) if footer && !footer.empty?
      @offsets = (@types + (@annual&.offsets || [])).uniq.freeze
      freeze
    end

    def fixed? = false
    def constant_offset = (@offsets.first if @transitions.empty? && @offsets.length == 1)
    def ==(other) = equal?(other) || (other.is_a?(ZoneRules) && !id.nil? && id == other.id)

    def offset_utc(epoch)
      epoch -= PERIOD if epoch > 31_556_889_832_715_999
      epoch += PERIOD if epoch < -31_557_014_135_532_000
      if @annual && (@transitions.empty? || epoch >= @transitions.last)
        return @annual.offset_utc(epoch)
      end
      index = @transitions.bsearch_index { it > epoch } || @transitions.length
      index.zero? ? @types[0] : @transition_offsets[index - 1]
    end

    def offset_local(date, nanos)
      local_offsets(date, nanos).first
    end

    def epoch_local(date, nanos)
      date.absolute_day * 86_400 + nanos / Temporal::SECOND - local_offsets(date, nanos).last
    end

    private

    def header(bytes, start)
      unless bytes.byteslice(start, 4) == "TZif" && [0, 50, 51, 52].include?(bytes.getbyte(start + 4)) && bytes.bytesize >= start + 44
        raise Error.new(90008, "Invalid time zone data header")
      end
      bytes.byteslice(start + 20, 24).unpack("N6")
    end

    def block_size(counts, width)
      ut, standard, leap, times, types, chars = counts
      times * (width + 1) + types * 6 + chars + leap * (width + 4) + standard + ut
    end

    def local_offsets(date, nanos)
      year = date.year
      year -= 400 if year > 999_999_999
      year += 400 if year < -999_999_999
      date = DateValue.new(year, date.month, date.day)
      wall = date.absolute_day * 86_400 + nanos / Temporal::SECOND
      valid = @offsets.select { offset_utc(wall - it) == it }
      return [valid.max, valid.max] unless valid.empty?

      index = @transitions.bsearch_index { it > wall - 172_800 } || @transitions.length
      transitions = []
      while index < @transitions.length && @transitions[index] <= wall + 172_800
        transitions << [@transitions[index], index.zero? ? @types[0] : @transition_offsets[index - 1], @transition_offsets[index]]
        index += 1
      end
      if @annual
        transitions.concat((year - 1..year + 1).flat_map { @annual.transitions(it) }.select { @transitions.empty? || it[0] >= @transitions.last })
      end
      gap = transitions.find { |at, before, after| before < after && wall >= at + before && wall < at + after }
      raise Error.new(90008, "Cannot resolve local time zone offset") unless gap

      [gap[2], gap[1]]
    end
  end
end

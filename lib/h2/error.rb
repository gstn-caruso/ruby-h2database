# frozen_string_literal: true

module H2
  class Error < StandardError
    STATES = {7001 => "07001", 21002 => "21S02", 42101 => "42S01", 42102 => "42S02",
      42121 => "42S21", 42122 => "42S22", 42123 => "42S23", 50100 => "HYC00", 50200 => "HYT00"}.freeze

    attr_reader :code, :sql_state

    def initialize(code, message)
      @code = code
      @sql_state = STATES.fetch(code, code.to_s)
      super("#{message} [#{code}]")
    end
  end
end

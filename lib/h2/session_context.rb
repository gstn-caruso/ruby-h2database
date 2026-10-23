# frozen_string_literal: true

module H2
  class SessionContext
    def start_statement
      @statement_time = Time.now
    end

    def current_timestamp
      @current_timestamp ||= Temporal.from_ruby(@statement_time || Time.now)
    end

    def current_date
      current_timestamp.date
    end

    def end_transaction
      @current_timestamp = nil
    end
  end
end

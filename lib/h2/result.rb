# frozen_string_literal: true

module H2
  class Result
    include Enumerable

    attr_reader :columns, :rows, :update_count

    def initialize(columns: [], rows: [], update_count: nil)
      @columns = columns.map { it.dup.freeze }.freeze
      @rows = rows.map do |row|
        row.map { it.is_a?(String) ? it.dup.freeze : it }.freeze
      end.freeze
      @update_count = update_count
      freeze
    end

    def query?
      update_count.nil?
    end

    def each
      return enum_for(__method__) unless block_given?

      rows.each { yield columns.zip(it).to_h }
      self
    end
  end
end

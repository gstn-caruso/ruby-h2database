# frozen_string_literal: true

module H2
  class Table
    attr_reader :name, :columns, :keys, :rows, :last_row_id

    def initialize(name, columns, keys, rows = [], row_ids: nil, last_row_id: 0)
      @name = name
      @columns = columns.freeze
      @keys = keys.freeze
      @rows = rows
      @row_ids = row_ids || {}.compare_by_identity
      @last_row_id = last_row_id
      duplicates = columns.group_by(&:name).find { |_name, group| group.length > 1 }
      raise Error.new(42121, "Duplicate column #{duplicates.first}") if duplicates
      raise Error.new(90017, "Multiple primary keys") if keys.count(&:primary) > 1

      keys.each { |key| validate_columns(key.columns) }
    end

    def copy
      self.class.new(name, columns, keys, rows.dup, row_ids: @row_ids.dup, last_row_id: last_row_id)
    end

    def row_id(row)
      @row_ids[row]
    end

    def assign_row_id(row, id)
      @row_ids[row] = id
      @last_row_id = [last_row_id, id].max
    end

    def truncate
      rows.clear
      @row_ids.clear
      @last_row_id = 0
    end

    def validate_columns(names)
      duplicate = names.tally.find { |_name, count| count > 1 }
      raise Error.new(42121, "Duplicate column #{duplicate.first}") if duplicate

      names.each do |column_name|
        raise Error.new(42122, "Column #{column_name} not found") unless columns.any? { it.name == column_name }
      end
    end

    def convert_row(values, existing_row: nil)
      row = columns.to_h do |column|
        value = column.type.convert(values.fetch(column.name))
        primary = keys.any? { it.primary && it.columns.include?(column.name) }
        if value.nil? && (!column.nullable || primary)
          raise Error.new(23502, "NULL not allowed for #{column.name}")
        end
        [column.name, value]
      end.freeze
      @row_ids[row] = @row_ids[existing_row] if existing_row && @row_ids.key?(existing_row)
      row
    end

    def validate_constraints
      keys.each do |key|
        seen = {}
        rows.each do |row|
          values = key.columns.map { row.fetch(it) }
          next if !key.primary && values.any?(&:nil?)
          raise Error.new(23505, "Unique key violation on #{key.columns.join(', ')}") if seen.key?(values)

          seen[values] = true
        end
      end
    end

    def seal
      rows.freeze
      @row_ids.freeze
      freeze
    end
  end
end

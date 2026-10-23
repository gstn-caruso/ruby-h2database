# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class RowType < Data.define(:column_count, :sort_types, :indexes, :store_keys)
        include Type

        def initialize(column_count:, sort_types:, indexes: nil, store_keys: true)
          raise ArgumentError, "Invalid row column count" unless column_count.is_a?(Integer) && (0..16_384).cover?(column_count)
          raise ArgumentError, "Invalid row index list" unless indexes.nil? || indexes.is_a?(Array)
          raise ArgumentError, "Invalid row key setting" unless [true, false].include?(store_keys)
          unless (sort_types.nil? && indexes.nil?) || (sort_types.is_a?(Array) && sort_types.length == (indexes ? indexes.length : column_count) && sort_types.all? { it.is_a?(Integer) && (0..7).cover?(it) })
            raise ArgumentError, "Invalid row sort types"
          end
          if indexes && (!indexes.all? { it.is_a?(Integer) && (0...column_count).cover?(it) } || indexes.uniq != indexes)
            raise ArgumentError, "Invalid row index columns"
          end

          super(column_count: column_count, sort_types: sort_types&.dup&.freeze, indexes: indexes&.dup&.freeze, store_keys: store_keys)
        end

        def copy(row)
          raise ArgumentError, "Expected a matching SearchRow" unless row.is_a?(SearchRow) && row.values.length == column_count
          unless columns.all? { row.values[it].is_a?(Value) }
            raise ArgumentError, "Missing stored row value"
          end

          row
        end

        def compare(left, right)
          columns.each_with_index do |column, index|
            a, b = left.values[column], right.values[column]
            break if a.nil? || b.nil?

            raise Error.new(5, "Row comparison requires sort types") unless sort_types

            flags = sort_types[index]
            result = if a.type == :null || b.type == :null
              if a.type == b.type
                0
              else
                null_first = (flags & 2) != 0 || ((flags & 4).zero? && (flags & 1).zero?)
                (a.type == :null ? -1 : 1) * (null_first ? 1 : -1)
              end
            else
              VALUE.compare(a, b) * ((flags & 1).zero? ? 1 : -1)
            end
            return result unless result.zero?
          end
          return 0 unless indexes
          return 0 if [left.key, right.key].include?(-(1 << 63) + 1)

          left.key <=> right.key
        end

        def write(buffer, row)
          copy(row)
          DataUtils.write_var_long(buffer, row.key) if store_keys
          columns.each { VALUE.write(buffer, row.values[it]) }
        end

        def read(buffer)
          key = store_keys ? DataUtils.read_var_long(buffer) : 0
          values = Array.new(column_count)
          columns.each { values[it] = VALUE.read(buffer) }
          SearchRow.new(key, values)
        end

        private

        def columns
          indexes || (0...column_count)
        end
      end
    end
  end
end

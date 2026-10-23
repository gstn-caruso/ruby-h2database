# frozen_string_literal: true

module H2
  module Persistence
    module ValueAdapter
      module_function

      def encode(value, type)
        return MVStore::Value.new(:null, nil) if value.nil?
        if type.is_a?(RowType)
          return MVStore::Value.new(:row, type.fields.each_with_index.map { |field, index| encode(value.values[index], field) })
        end
        data = if type.name == "NUMERIC"
          scale = type.scale || 0
          MVStore::Decimal.new((value * (10**scale)).to_i, scale)
        else
          value
        end
        MVStore::Value.new(type.name.downcase.to_sym, data)
      end

      def decode(value, type)
        return nil if value.type == :null
        if type.is_a?(RowType)
          unless value.type == :row && value.data.length == type.fields.length
            raise Error.new(90030, "Stored row does not match its column type")
          end
          return RowValue.new(type.fields.each_with_index.map { |field, index| decode(value.data[index], field) })
        end
        type.convert(value.to_ruby)
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module Persistence
    module ValueAdapter
      module_function

      def encode(value, type)
        return MVStore::Value.new(:null, nil) if value.nil?
        if type.is_a?(ArrayType)
          return MVStore::Value.new(:array, value.values.map { encode(it, type.element_type) })
        end
        if type.is_a?(RowType)
          return MVStore::Value.new(:row, type.fields.each_with_index.map { |field, index| encode(value.values[index], field) })
        end
        if Intervals.name?(type.name)
          return MVStore::Value.new(:interval, [value.ordinal, value.negative, value.leading, value.remaining])
        end
        data = if type.name == "ENUM"
          value.ordinal
        elsif type.name == "NUMERIC"
          scale = type.scale || 0
          MVStore::Decimal.new((value * (10**scale)).to_i, scale)
        elsif type.name == "DECFLOAT"
          value.special || MVStore::Decimal.new(value.unscaled, value.scale)
        elsif %w[UUID JSON].include?(type.name)
          value.bytes
        elsif type.name == "DATE"
          value.packed
        elsif type.name == "TIME"
          value.nanos
        elsif type.name == "TIMESTAMP"
          [value.date.packed, value.time.nanos]
        elsif type.name == "TIME WITH TIME ZONE"
          [value.nanos, value.offset_seconds]
        elsif type.name == "TIMESTAMP WITH TIME ZONE"
          [value.date.packed, value.time.nanos, value.offset_seconds]
        else
          value
        end
        kind = {"TIME WITH TIME ZONE" => :time_tz, "TIMESTAMP WITH TIME ZONE" => :timestamp_tz}.fetch(type.name) { type.name.downcase.to_sym }
        MVStore::Value.new(kind, data)
      end

      def decode(value, type, context: nil)
        return nil if value.type == :null
        if type.is_a?(ArrayType)
          raise Error.new(90030, "Stored value is not an array") unless value.type == :array

          return type.convert(ArrayValue.new(value.data.map { decode(it, type.element_type, context: context) }, type.element_type), context: context)
        end
        if type.is_a?(RowType)
          unless value.type == :row && value.data.length == type.fields.length
            raise Error.new(90030, "Stored row does not match its column type")
          end
          return RowValue.new(values: type.fields.each_with_index.map { |field, index| decode(value.data[index], field, context: context) }, type: type)
        end
        data = case value.type
        when :date then DateValue.from_packed(value.data)
        when :time then TimeValue.new(value.data)
        when :timestamp then TimestampValue.new(DateValue.from_packed(value.data[0]), TimeValue.new(value.data[1]))
        when :time_tz then TimeTimeZoneValue.new(*value.data)
        when :timestamp_tz then TimestampTimeZoneValue.new(DateValue.from_packed(value.data[0]), TimeValue.new(value.data[1]), value.data[2])
        when :interval then IntervalValue.new(IntervalUnits::QUALIFIERS.fetch(value.data[0]), *value.data.drop(1))
        when :json then JsonValue.parse(value.data)
        when :decfloat
          value.data.is_a?(MVStore::Decimal) ? DecfloatValue.new(value.data.unscaled, value.data.scale, nil) : DecfloatValue.new(0, 0, value.data)
        else value.to_ruby
        end
        type.convert(data, context: context)
      end
    end
  end
end

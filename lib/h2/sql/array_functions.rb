# frozen_string_literal: true

module H2
  module SQL
    module ArrayFunctions
      ARITIES = {"CARDINALITY" => 1..1, "ARRAY_MAX_CARDINALITY" => 1..1, "TRIM_ARRAY" => 2..2,
        "ARRAY_CONTAINS" => 2..2, "ARRAY_SLICE" => 3..3}.freeze
      module_function

      def type(name, argument)
        case name
        when "CARDINALITY", "ARRAY_MAX_CARDINALITY" then Type.new("INTEGER", nil, 0)
        when "ARRAY_CONTAINS" then Type.new("BOOLEAN", nil, nil)
        else
          raise Error.new(50004, "Array argument type is unknown") if argument.name == "UNKNOWN"
          unless argument.is_a?(ArrayType) || argument.name == "NULL"
            raise Error.new(90008, "#{name} requires an array")
          end
          argument
        end
      end

      def evaluate(name, argument_type, value, equals)
        if name == "ARRAY_MAX_CARDINALITY"
          raise Error.new(90008, "Expected array") unless argument_type.is_a?(ArrayType)

          return argument_type.precision
        end
        array = value.call(0)
        if name == "ARRAY_CONTAINS"
          candidate = value.call(1)
          return nil unless array.is_a?(ArrayValue) || array.is_a?(RowValue)

          element_type = array.is_a?(ArrayValue) ? array.element_type : nil
          return array.values.any? { equals.call(it, candidate, element_type) }
        end
        if name == "CARDINALITY"
          return nil if array.nil?
          raise Error.new(90008, "Expected array") unless array.is_a?(ArrayValue)

          return array.values.length
        end
        index = value.call(1)
        return nil if index.nil?

        if name == "TRIM_ARRAY"
          index = Type.new("INTEGER", nil, nil).convert(index)
          raise Error.new(22034, "Negative array trim") if index.negative?
          return nil if array.nil?
          raise Error.new(22034, "Trim exceeds array cardinality") if index > array.values.length

          return ArrayValue.new(array.values.first(array.values.length - index), array.element_type)
        end
        return nil if array.nil?

        finish = value.call(2)
        return nil if finish.nil?

        index = Type.new("INTEGER", nil, nil).convert(index)
        start = (index - 1 + 2**31) % 2**32 - 2**31
        finish = Type.new("INTEGER", nil, nil).convert(finish)
        return nil if start > finish || start.negative? || finish > array.values.length

        ArrayValue.new(array.values[start...finish], array.element_type)
      end
    end
  end
end

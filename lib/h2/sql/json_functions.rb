# frozen_string_literal: true

module H2
  module SQL
    module JsonFunctions
      module_function

      def predicate(node, value)
        return nil if value.nil?

        result = begin
          source = value.is_a?(BlobValue) ? value.bytes : (value.is_a?(ClobValue) ? value.to_s : value)
          json = source.is_a?(JsonValue) ? source : (JsonValue.parse(source) if source.is_a?(String))
          json && (node.item_type == :value || node.item_type == json.kind) && (!node.unique_keys || json.unique_keys?)
        rescue Error
          false
        end
        node.negated ? !result : !!result
      end

      def type_predicate(node, value, type)
        return nil if value.nil?

        name = ->(item) { item.is_a?(ArrayType) ? "ARRAY" : item.name }
        result = node.types.any? { name.call(it) == name.call(type) }
        node.negated ? !result : result
      end

      def format(value, type)
        return nil if value.nil?

        value.is_a?(ClobValue) || (value.is_a?(String) && !BinaryString.binary?(value)) ? JsonValue.parse(value.to_s) : JsonValue.convert(value, source_type: type)
      end

      def construct(node, entries)
        values = []
        if node.kind == :array
          entries.each do |value|
            next if node.absent_on_null && value.null?

            values << value.node
          end
        else
          entries.each_slice(2) do |name, value|
            raise Error.new(90008, "NULL JSON_OBJECT key") if name.nil?
            next if node.absent_on_null && value.null?

            values << [name.freeze, value.node].freeze
          end
        end
        result = JsonValue.from_node(JsonDocument::Node.new(node.kind, values.freeze))
        raise Error.new(90008, "Duplicate JSON_OBJECT key") if node.unique_keys && !result.unique_keys?

        result
      end

      def flags(node)
        text = if node.absent_on_null
          node.kind == :object ? " ABSENT ON NULL" : ""
        else
          node.kind == :array ? " NULL ON NULL" : ""
        end
        text + (node.unique_keys ? " WITH UNIQUE KEYS" : "")
      end
    end
  end
end

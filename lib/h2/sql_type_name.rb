# frozen_string_literal: true

module H2
  module SQLTypeName
    ALIASES = {"VARCHAR" => "CHARACTER VARYING", "CHAR" => "CHARACTER", "VARBINARY" => "BINARY VARYING", "DOUBLE" => "DOUBLE PRECISION", "BLOB" => "BINARY LARGE OBJECT", "CLOB" => "CHARACTER LARGE OBJECT"}.freeze
    module_function

    def metadata(type, nested: false)
      return type.type_name if type.is_a?(EnumType)
      if type.is_a?(RowType)
        parts = ['ROW(']
        type.fields.each_with_index do |field, index|
          parts << ', ' if index.positive?
          parts.concat([CharacterString.identifier(type.names[index]),' ',metadata(field, nested: true)])
        end
        parts << ')'
      elsif type.is_a?(ArrayType)
        parts = [metadata(type.element_type, nested: true),' ARRAY',nested && type.precision != ArrayValue::MAX_CARDINALITY ? "[#{type.precision}]" : '']
      else
        return format(type)
      end
      CharacterString.join(parts)
    end

    def format(type)
      return type.sql if type.is_a?(EnumType)
      if type.is_a?(RowType)
        return "ROW(#{type.fields.each_with_index.map { |field, index| "#{CharacterString.identifier(type.names[index])} #{format(field)}" }.join(', ')})"
      end
      if type.is_a?(ArrayType)
        return "#{format(type.element_type)} ARRAY#{type.precision == ArrayValue::MAX_CARDINALITY ? '' : "[#{type.precision}]"}"
      end
      return Intervals.sql(type) if Intervals.name?(type.name)

      name = type.declared_name || ALIASES.fetch(type.name, type.name)
      if type.declared_name == "FLOAT"
        return name + (type.declared_precision ? "(#{type.declared_precision})" : '')
      end
      if LobValues::NAMES.include?(type.name)
        name += "(#{type.precision})" if type.declared_precision || (type.precision && type.precision != LobValues::MAX_PRECISION)
      elsif type.name == "JSON" && type.precision && type.precision != JsonValue::MAX_PRECISION
        name += "(#{type.precision})"
      elsif type.name == "DECFLOAT" && type.precision && type.precision != 100_000
        name += "(#{type.precision})"
      elsif %w[CHAR VARCHAR BINARY VARBINARY].include?(type.name) && type.precision
        name += "(#{type.precision})"
      elsif type.name == "NUMERIC" && !type.declared_scale.nil?
        name += "(#{type.precision || 100_000}, #{type.declared_scale})"
      elsif type.name == "NUMERIC" && type.declared_precision
        name += "(#{type.declared_precision})"
      elsif type.name == "NUMERIC" && type.precision && [type.precision, type.scale] != [100_000, 0]
        name += "(#{type.precision}#{type.scale.to_i.zero? ? '' : ", #{type.scale}"})"
      elsif Temporal::NAMES.include?(type.name) && type.name != "DATE" && type.scale != (Temporal.time_type?(type.name) ? 0 : 6)
        name = name.sub(/\A(TIMESTAMP|TIME)/) { "#{it}(#{type.scale})" }
      end
      name
    end
  end
end

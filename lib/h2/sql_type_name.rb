# frozen_string_literal: true

module H2
  module SQLTypeName
    ALIASES = {"VARCHAR" => "CHARACTER VARYING", "CHAR" => "CHARACTER", "VARBINARY" => "BINARY VARYING", "DOUBLE" => "DOUBLE PRECISION"}.freeze
    module_function

    def format(type)
      if type.is_a?(RowType)
        return "ROW(#{type.fields.each_with_index.map { |field, index| "\"C#{index + 1}\" #{format(field)}" }.join(', ')})"
      end
      if type.is_a?(ArrayType)
        return "#{format(type.element_type)} ARRAY#{type.precision == ArrayValue::MAX_CARDINALITY ? '' : "[#{type.precision}]"}"
      end
      return Intervals.sql(type) if Intervals.name?(type.name)

      name = ALIASES.fetch(type.name, type.name)
      if type.name == "JSON" && type.precision && type.precision != JsonValue::MAX_PRECISION
        name += "(#{type.precision})"
      elsif type.name == "DECFLOAT" && type.precision && type.precision != 100_000
        name += "(#{type.precision})"
      elsif %w[CHAR VARCHAR BINARY VARBINARY].include?(type.name) && type.precision
        name += "(#{type.precision})"
      elsif type.name == "NUMERIC" && !type.declared_scale.nil?
        name += "(#{type.precision || 100_000}, #{type.declared_scale})"
      elsif type.name == "NUMERIC" && type.precision && [type.precision, type.scale] != [100_000, 0]
        name += "(#{type.precision}#{type.scale.to_i.zero? ? '' : ", #{type.scale}"})"
      elsif Temporal::NAMES.include?(type.name) && type.name != "DATE" && type.scale != (Temporal.time_type?(type.name) ? 0 : 6)
        name = name.sub(/\A(TIMESTAMP|TIME)/) { "#{it}(#{type.scale})" }
      end
      name
    end
  end
end

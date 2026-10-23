# frozen_string_literal: true

module H2
  module SQL
    module MathFunctions
      ARITIES = {"ROUND" => 1..2, "FLOOR" => 1..1, "CEIL" => 1..1, "TRUNC" => 1..2, "ROUNDMAGIC" => 1..1}.freeze
      ALIASES = {"CEILING" => "CEIL", "TRUNCATE" => "TRUNC"}.freeze
      MODES = {"ROUND" => :half_up, "FLOOR" => :floor, "CEIL" => :ceiling, "TRUNC" => :down}.freeze
      TEMPORAL_TRUNC = %w[VARCHAR DATE TIMESTAMP TIMESTAMP\ WITH\ TIME\ ZONE].freeze
      module_function

      def scale(value)
        value = Type.new("INTEGER", nil, 0).convert(value)
        raise Error.new(90008, "Rounding scale is outside -100000..100000") unless (-100_000..100_000).cover?(value)

        value
      end

      def plan(node, argument_type, known_scale:, scale_value:)
        return [node, Type.new("DOUBLE", nil, nil)] if node.name == "ROUNDMAGIC"
        if node.name == "TRUNC" && TEMPORAL_TRUNC.include?(argument_type.name)
          raise Error.new(7001, "Temporal TRUNC requires one argument") if node.arguments.length != 1
          argument = node.arguments.first
          return [Cast.new(argument, Temporal.type("TIMESTAMP", 0)), Temporal.type("TIMESTAMP", 0)] if argument_type.name == "DATE"

          argument = Cast.new(argument, Temporal.type("TIMESTAMP", 0)) if argument_type.name == "VARCHAR"
          return [Function.new("DATE_TRUNC", [Literal.new("DAY"), argument], false), nil]
        end
        scale_is_null = known_scale && scale_value.nil?
        requested = scale_is_null ? -1 : scale_value
        type = case argument_type.name
        when "NULL" then Type.new("NUMERIC", 100_000, 0, 0)
        when *Type::INTEGER_LIMITS.keys
          return [node.arguments.first, argument_type] if known_scale && requested >= 0

          argument_type
        when "REAL", "DOUBLE", "DECFLOAT" then argument_type
        when "NUMERIC"
          original_scale = argument_type.scale || 0
          if known_scale
            return [node.arguments.first, argument_type] if original_scale <= requested

            target_scale = [[requested, 0].max, 100_000].min
            precision = (argument_type.precision || 100_000) - original_scale + target_scale
          else
            target_scale = original_scale
            precision = argument_type.precision || 100_000
          end
          precision += 1 unless node.name == "TRUNC"
          precision = 100_000 if precision < 1
          Type.new("NUMERIC", [precision, 100_000].min, target_scale, target_scale)
        when "UNKNOWN" then raise Error.new(50004, "Unknown rounding argument type")
        else raise Error.new(90008, "Invalid #{node.name} argument type")
        end
        scale_is_null ? [TypedLiteral.new(nil, type, true), type] : [node, type]
      end

      def evaluate(name, value, type, requested_scale, source_type)
        return magic(Type.new("DOUBLE", nil, nil).convert(value)) if name == "ROUNDMAGIC"

        mode = MODES.fetch(name)
        if Type::INTEGER_LIMITS.key?(type.name)
          return value if requested_scale >= 0
          return 0 if requested_scale < -18

          rounded = DecfloatValue.convert(value).quantize(requested_scale, mode)
          return type.convert(rounded)
        end
        if %w[REAL DOUBLE].include?(type.name) && requested_scale.zero? && name != "ROUND"
          return value unless value.finite?

          rounded = case mode
          when :floor then value.floor
          when :ceiling then value.ceil
          when :down then value.truncate
          end
          return type.convert(rounded)
        end
        decimal = DecfloatValue.convert(value, source_type: source_type)
        if type.name == "NUMERIC"
          decimal = decimal.quantize(requested_scale, mode) if requested_scale < type.scale
          decimal.quantize(type.scale, mode).to_d
        else
          rounded = decimal.quantize(requested_scale, mode)
          type.name == "DECFLOAT" ? rounded : type.convert(rounded)
        end
      end

      def literal(value, type)
        return Literal.new(value) if value.is_a?(DecfloatValue)

        NumericOperations.literal(value, type)
      end

      def magic(value)
        return 0.0 if value > -1e-13 && value < 1e-13
        return value if value > 1e12 || value < -1e12

        text = JsonValue.float_text(value)
        return value if text.include?('E') || text.length < 16 || (text.index('.') || -1) > text.length - 3

        text = text[0...-2]
        if text[-4,3] == '000'
          text[-1] = '0'
        elsif text[-4,3] == '999'
          text[-1] = '9'
          text += '999'
        end
        Float(text)
      end
    end
  end
end

# frozen_string_literal: true

module H2
  module Persistence
    module SQLWriter
      module_function

      def identifier(value)
        return unicode_quote(value, '"') if [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(value.encoding)

        '"' + value.gsub('"', '""') + '"'
      end

      def unicode_quote(value, delimiter)
        body = MVStore::Codecs::STRING.units(value).map do |unit|
          if unit == delimiter.ord
            delimiter * 2
          elsif unit == 92
            "\\\\"
          elsif (32..126).cover?(unit)
            unit.chr
          else
            "\\#{unit.to_s(16).rjust(4, '0')}"
          end
        end.join
        "U&#{delimiter}#{body}#{delimiter}"
      end

      def table_name(value)
        "\"PUBLIC\".#{identifier(value)}"
      end

      def type(value)
        return value.sql if value.is_a?(EnumType)
        if value.is_a?(ArrayType)
          return "#{type(value.element_type)} ARRAY#{value.precision == ArrayValue::MAX_CARDINALITY ? '' : "[#{value.precision}]"}"
        end
        return Intervals.sql(value, explicit: true) if Intervals.name?(value.name)
        if value.is_a?(RowType)
          return "ROW(#{value.fields.each_with_index.map { |field, index| "#{identifier("C#{index + 1}")} #{type(field)}" }.join(', ')})"
        end
        case value.name
        when *(Temporal::NAMES - ["DATE"])
          value.name.sub(/\A(TIMESTAMP|TIME)/) { "#{it}(#{value.scale || (Temporal.time_type?(value.name) ? 0 : 6)})" }
        when "NUMERIC", "REAL", "DOUBLE", "JSON", "DECFLOAT" then SQLTypeName.format(value)
        when "VARCHAR", "CHAR", "BINARY", "VARBINARY" then value.precision ? "#{value.name}(#{value.precision})" : value.name
        else value.name
        end
      end

      def literal(value, type: nil)
        return "CAST(#{literal(value.label)} AS #{self.type(value.type)})" if value.is_a?(EnumValue)
        case value
        when nil then "NULL"
        when true then "TRUE"
        when false then "FALSE"
        when String
          if BinaryString.binary?(value)
            "X'#{value.unpack1('H*')}'"
          else
            [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(value.encoding) ? unicode_quote(value, "'") : "'#{value.gsub("'", "''")}'"
          end
        when UUIDValue then "UUID '#{value}'"
        when JsonValue then value.sql
        when DecfloatValue then value.sql
        when IntervalValue then value.to_s
        when DateValue, TimeValue, TimestampValue, TimeTimeZoneValue, TimestampTimeZoneValue then "#{Temporal.name(value)} '#{value}'"
        when BigDecimal then type&.name == "NUMERIC" ? ArrayType.decimal_text(value, type.scale) : value.to_s("F")
        when Integer then value.to_s
        when Float
          text = value.finite? ? value.to_s : "'#{value}'"
          "CAST(#{text} AS DOUBLE PRECISION)"
        when RowValue then "ROW(#{value.values.map { literal(it) }.join(', ')})"
        when ArrayValue
          text = "ARRAY[#{value.values.map { literal(it, type: value.element_type) }.join(', ')}]"
          value.element_type.name == "NULL" ? text : "CAST(#{text} AS #{self.type(ArrayType.new(value.element_type, value.values.length))})"
        else raise Error.new(50100, "Default SQL value has not been ported")
        end
      end

      def expression(node, parameters: [], ctes: [])
        render = ->(child) { expression(child, parameters: parameters, ctes: ctes) }
        case node
        when SQL::DecimalLiteral then node.text || ArrayType.decimal_text(node.value, node.scale)
        when SQL::TypedLiteral
          if node.value.is_a?(DecfloatValue)
            value = node.value
            "CAST(#{value.special ? "'#{value}'" : value.to_s} AS #{type(node.type)})"
          elsif node.value.is_a?(Float)
            text = JsonValue.float_text(node.value, real: node.type.name == "REAL")
            text = "'#{text}'" unless node.value.finite?
            "CAST(#{text} AS #{type(node.type)})"
          elsif node.value.is_a?(Integer) && Type::INTEGER_LIMITS.key?(node.type.name)
            "CAST(#{node.value} AS #{type(node.type)})"
          elsif BinaryString.binary?(node.value) && node.type.name == "BINARY"
            "CAST(#{literal(node.value)} AS #{type(node.type)})"
          elsif node.value.is_a?(BigDecimal) && node.type.name == "NUMERIC"
            text = ArrayType.decimal_text(node.value, node.type.scale)
            node.cast ? "CAST(#{text} AS #{type(node.type)})" : text
          else
            expression(node.cast ? SQL::Cast.new(SQL::Literal.new(node.value), node.type) : SQL::Literal.new(node.value), parameters: parameters, ctes: ctes)
          end
        when SQL::CurrentDateTime then node.name + (node.scale.nil? ? "" : "(#{node.scale})")
        when SQL::TimeZoneExpression then "(#{render.call(node.expression)} AT #{node.zone ? "TIME ZONE #{render.call(node.zone)}" : 'LOCAL'})"
        when SQL::CapturedExpression then expression(node.expression, parameters: node.parameters, ctes: ctes)
        when SQL::Literal then literal(node.value)
        when SQL::Parameter then literal(parameters.fetch(node.index))
        when SQL::ColumnRef then [node.qualifier, node.name].compact.map { identifier(it) }.join(".")
        when SQL::Star then node.qualifier ? "#{identifier(node.qualifier)}.*" : "*"
        when SQL::Unary then "(#{node.operator} #{render.call(node.operand)})"
        when SQL::Binary then "(#{render.call(node.left)} #{node.operator} #{render.call(node.right)})"
        when SQL::IntervalDifference then "(#{render.call(node.left)} - #{render.call(node.right)}) #{Intervals.sql(node.type, explicit: true).delete_prefix('INTERVAL ')}"
        when SQL::Cast then "CAST(#{render.call(node.expression)} AS #{type(node.type)})"
        when SQL::Function
          if node.name == "EXTRACT"
            "EXTRACT(#{node.arguments.first.value} FROM #{render.call(node.arguments.last)})"
          elsif SQL::DateTimeFunctions::NAMES.include?(node.name) || node.name == "DATE_TRUNC"
            "#{node.name}(#{node.arguments.first.value}, #{node.arguments.drop(1).map { render.call(it) }.join(', ')})"
          else
            "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { render.call(it) }.join(', ')})"
          end
        when SQL::Aggregate
          body = "#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { render.call(it) }.join(', ')}"
          unless node.order.empty?
            body += " ORDER BY " + node.order.map do |ordering|
              render.call(ordering.expression) + (ordering.descending ? " DESC" : " ASC") +
                (ordering.nulls ? " NULLS #{ordering.nulls.to_s.upcase}" : "")
            end.join(', ')
          end
          "#{node.name}(#{body})" + (node.filter ? " FILTER(WHERE #{render.call(node.filter)})" : "")
        when SQL::RowConstructor then "ROW(#{node.expressions.map { render.call(it) }.join(', ')})"
        when SQL::ArrayConstructor then "ARRAY[#{node.expressions.map { render.call(it) }.join(', ')}]"
        when SQL::ArrayElement then "(#{render.call(node.array)})[#{render.call(node.index)}]"
        when SQL::ArrayQuery then "ARRAY(#{query(node.query, parameters: parameters, ctes: ctes)})"
        when SQL::Subquery then "(#{query(node.query, parameters: parameters, ctes: ctes)})"
        when SQL::Exists then "EXISTS(#{query(node.query, parameters: parameters, ctes: ctes)})"
        when SQL::InQuery
          body = "#{render.call(node.expression)} #{node.operator} #{node.all ? 'ALL' : 'ANY'}(#{query(node.query, parameters: parameters, ctes: ctes)})"
          "(#{node.negated ? 'NOT (' + body + ')' : body})"
        when SQL::QuantifiedArray
          "(#{render.call(node.expression)} #{node.operator} #{node.all ? 'ALL' : 'ANY'}(#{render.call(node.array)}))"
        when SQL::JsonFormat then "(#{render.call(node.expression)} FORMAT JSON)"
        when SQL::JsonPredicate
          "(#{render.call(node.expression)} IS#{node.negated ? ' NOT' : ''} JSON#{node.item_type == :value ? '' : ' ' + node.item_type.to_s.upcase}#{node.unique_keys ? ' WITH UNIQUE KEYS' : ''})"
        when SQL::TypePredicate
          "(#{render.call(node.expression)} IS#{node.negated ? ' NOT' : ''} OF (#{node.types.map { type(it) }.join(', ')}))"
        when SQL::JsonConstructor
          arguments = node.arguments.map { render.call(it) }
          arguments = arguments.each_slice(2).map { |key, value| "#{key}: #{value}" } if node.kind == :object
          "JSON_#{node.kind.to_s.upcase}(#{arguments.join(', ')}#{SQL::JsonFunctions.flags(node)})"
        when SQL::WhenPredicate
          predicate = node.predicate
          first = predicate.is_a?(SQL::Binary) ? predicate.left : (predicate.is_a?(SQL::Predicate) ? predicate.arguments.first : predicate.expression)
          text = render.call(predicate)
          text = text[1...-1] if text.start_with?("(") && text.end_with?(")")
          text.delete_prefix(render.call(first)).lstrip
        when SQL::CaseExpression
          sql = "CASE" + (node.operand ? " #{render.call(node.operand)}" : "")
          node.branches.each { |condition, value| sql += " WHEN #{render.call(condition)} THEN #{render.call(value)}" }
          sql + " ELSE #{render.call(node.fallback)} END"
        when SQL::Predicate
          args = node.arguments.map { render.call(it) }
          body = case node.operator
          when :is then "#{args[0]} IS #{args[1]}"
          when :is_not then "#{args[0]} IS NOT #{args[1]}"
          when :distinct then "#{args[0]} IS DISTINCT FROM #{args[1]}"
          when :not_distinct then "#{args[0]} IS NOT DISTINCT FROM #{args[1]}"
          when :between then "#{args[0]} BETWEEN #{args[1]} AND #{args[2]}"
          when :in then "#{args[0]} IN(#{args.drop(1).join(', ')})"
          when :like then "#{args[0]} LIKE #{args[1]} ESCAPE #{args[2]}"
          else raise Error.new(50100, "Default predicate has not been ported")
          end
          "(#{body})"
        else raise Error.new(50100, "Default expression serialization has not been ported")
        end
      end

      def query(node, parameters: [], ctes: [])
        return with_query(node, parameters: parameters, ctes: ctes) if node.is_a?(SQL::WithQuery)

        render = ->(child) { expression(child, parameters: parameters, ctes: ctes) }
        sql = case node
        when SQL::SetQuery
          operator = {union: "UNION", union_all: "UNION ALL", except: "EXCEPT", intersect: "INTERSECT"}.fetch(node.operator)
          "(#{query(node.left, parameters: parameters, ctes: ctes)}) #{operator} (#{query(node.right, parameters: parameters, ctes: ctes)})"
        when SQL::Values
          "VALUES " + node.rows.map { |row| "(#{row.map { render.call(it) }.join(', ')})" }.join(", ")
        when SQL::Select
          text = "SELECT#{node.distinct ? ' DISTINCT' : ''} " + node.projections.map do |projection|
            render.call(projection.expression) + (projection.label ? " AS #{identifier(projection.label)}" : "")
          end.join(", ")
          text += " FROM #{source(node.source, parameters: parameters, ctes: ctes)}" if node.source
          text += " WHERE #{render.call(node.where)}" if node.where
          text += " GROUP BY #{node.group.map { render.call(it) }.join(', ')}" unless node.group.empty?
          text += " HAVING #{render.call(node.having)}" if node.having
          text
        else raise Error.new(50100, "Default query serialization has not been ported")
        end
        unless node.order.empty?
          sql += " ORDER BY " + node.order.map do |order|
            expression = render.call(order.expression)
            expression = "(#{expression})" if !order.position && order.expression.is_a?(SQL::Literal) && order.expression.value.is_a?(Integer)
            expression + (order.descending ? " DESC" : " ASC") + (order.nulls ? " NULLS #{order.nulls.to_s.upcase}" : "")
          end.join(", ")
        end
        sql += " LIMIT #{render.call(node.limit)}" if node.limit
        sql += " OFFSET #{render.call(node.offset)} ROWS" if node.offset
        sql
      end

      def with_query(node, parameters:, ctes:)
        visible = ctes.dup
        definitions = node.definitions.map do |definition|
          scope = node.recursive ? visible + [definition.name] : visible
          sql = identifier(definition.name)
          sql += "(#{definition.columns.map { identifier(it) }.join(', ')})" if definition.columns
          sql += " AS (#{query(definition.query, parameters: parameters, ctes: scope)})"
          visible << definition.name
          sql
        end
        "WITH#{node.recursive ? ' RECURSIVE' : ''} #{definitions.join(', ')} #{query(node.query, parameters: parameters, ctes: visible)}"
      end

      def source(node, parameters: [], ctes: [])
        case node
        when SQL::TableSource
          !node.qualified && ctes.include?(node.name) ? identifier(node.name) : table_name(node.name)
        when SQL::RangeSource then "#{node.name}(#{node.arguments.map { expression(it, parameters: parameters, ctes: ctes) }.join(', ')})"
        when SQL::UnnestSource
          arguments = node.arguments.each_with_index.map do |argument, index|
            text = expression(argument, parameters: parameters, ctes: ctes)
            node.types[index].name == "NULL" ? "COALESCE(#{text}, NULL)" : text
          end
          "UNNEST(#{arguments.join(', ')})#{node.ordinality ? ' WITH ORDINALITY' : ''}"
        when SQL::DerivedSource then "(#{query(node.query, parameters: parameters, ctes: ctes)})"
        when SQL::AliasedSource
          text = "#{source(node.source, parameters: parameters, ctes: ctes)} AS #{identifier(node.name)}"
          text += "(#{node.columns.map { identifier(it) }.join(', ')})" if node.columns
          text
        when SQL::JoinSource
          operator = {inner: "INNER JOIN", left: "LEFT JOIN", right: "RIGHT JOIN", cross: "CROSS JOIN"}.fetch(node.kind)
          operator = "NATURAL #{operator}" if node.natural
          text = "#{source(node.left, parameters: parameters, ctes: ctes)} #{operator} #{source(node.right, parameters: parameters, ctes: ctes)}"
          text += " ON #{expression(node.condition, parameters: parameters, ctes: ctes)}" if node.condition
          text += " USING(#{node.using_columns.map { identifier(it) }.join(', ')})" unless node.using_columns.empty?
          "(#{text})"
        else raise Error.new(50100, "Default source serialization has not been ported")
        end
      end

      def create_table(table)
        primary = table.keys.select(&:primary).flat_map(&:columns)
        columns = table.columns.map do |column|
          sql = "#{identifier(column.name)} #{type(column.type)}"
          sql += " DEFAULT #{expression(column.default)}" if column.default
          sql += " NOT NULL" if !column.nullable || primary.include?(column.name)
          sql
        end
        "CREATE CACHED TABLE #{table_name(table.name)}(#{columns.join(', ')})"
      end
    end
  end
end

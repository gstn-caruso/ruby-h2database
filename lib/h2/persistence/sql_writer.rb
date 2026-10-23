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
        if value.is_a?(RowType)
          return "ROW(#{value.fields.each_with_index.map { |field, index| "#{identifier("C#{index + 1}")} #{type(field)}" }.join(', ')})"
        end
        case value.name
        when "NUMERIC" then "NUMERIC(#{value.precision || 100_000},#{value.scale || 0})"
        when "VARCHAR", "CHAR" then value.precision ? "#{value.name}(#{value.precision})" : value.name
        else value.name
        end
      end

      def literal(value)
        case value
        when nil then "NULL"
        when true then "TRUE"
        when false then "FALSE"
        when String
          [Encoding::UTF_16BE, Encoding::UTF_16LE].include?(value.encoding) ? unicode_quote(value, "'") : "'#{value.gsub("'", "''")}'"
        when BigDecimal then value.to_s("F")
        when Integer then value.to_s
        when Float
          raise Error.new(50100, "Non-finite default SQL has not been ported") unless value.finite?

          "CAST(#{value.to_s} AS DOUBLE PRECISION)"
        when RowValue then "ROW(#{value.values.map { literal(it) }.join(', ')})"
        else raise Error.new(50100, "Default SQL value has not been ported")
        end
      end

      def expression(node, parameters: [])
        render = ->(child) { expression(child, parameters: parameters) }
        case node
        when SQL::CapturedExpression then expression(node.expression, parameters: node.parameters)
        when SQL::Literal then literal(node.value)
        when SQL::Parameter then literal(parameters.fetch(node.index))
        when SQL::ColumnRef then [node.qualifier, node.name].compact.map { identifier(it) }.join(".")
        when SQL::Star then node.qualifier ? "#{identifier(node.qualifier)}.*" : "*"
        when SQL::Unary then "(#{node.operator} #{render.call(node.operand)})"
        when SQL::Binary then "(#{render.call(node.left)} #{node.operator} #{render.call(node.right)})"
        when SQL::Cast then "CAST(#{render.call(node.expression)} AS #{type(node.type)})"
        when SQL::Function then "#{node.name}(#{node.distinct ? 'DISTINCT ' : ''}#{node.arguments.map { render.call(it) }.join(', ')})"
        when SQL::RowConstructor then "ROW(#{node.expressions.map { render.call(it) }.join(', ')})"
        when SQL::Subquery then "(#{query(node.query, parameters: parameters)})"
        when SQL::Exists then "EXISTS(#{query(node.query, parameters: parameters)})"
        when SQL::InQuery then "(#{render.call(node.expression)} IN(#{query(node.query, parameters: parameters)}))"
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

      def query(node, parameters: [])
        render = ->(child) { expression(child, parameters: parameters) }
        sql = case node
        when SQL::Values
          "VALUES " + node.rows.map { |row| "(#{row.map { render.call(it) }.join(', ')})" }.join(", ")
        when SQL::Select
          text = "SELECT#{node.distinct ? ' DISTINCT' : ''} " + node.projections.map do |projection|
            render.call(projection.expression) + (projection.label ? " AS #{identifier(projection.label)}" : "")
          end.join(", ")
          text += " FROM #{source(node.source, parameters: parameters)}" if node.source
          text += " WHERE #{render.call(node.where)}" if node.where
          text += " GROUP BY #{node.group.map { render.call(it) }.join(', ')}" unless node.group.empty?
          text += " HAVING #{render.call(node.having)}" if node.having
          text
        else raise Error.new(50100, "Default query serialization has not been ported")
        end
        unless node.order.empty?
          sql += " ORDER BY " + node.order.map do |order|
            render.call(order.expression) + (order.descending ? " DESC" : " ASC") + (order.nulls ? " NULLS #{order.nulls.to_s.upcase}" : "")
          end.join(", ")
        end
        sql += " LIMIT #{render.call(node.limit)}" if node.limit
        sql += " OFFSET #{render.call(node.offset)} ROWS" if node.offset
        sql
      end

      def source(node, parameters: [])
        case node
        when SQL::TableSource then table_name(node.name)
        when SQL::RangeSource then "#{node.name}(#{node.arguments.map { expression(it, parameters: parameters) }.join(', ')})"
        when SQL::DerivedSource then "(#{query(node.query, parameters: parameters)})"
        when SQL::AliasedSource
          text = "#{source(node.source, parameters: parameters)} AS #{identifier(node.name)}"
          text += "(#{node.columns.map { identifier(it) }.join(', ')})" if node.columns
          text
        when SQL::JoinSource
          operator = {inner: "INNER JOIN", left: "LEFT JOIN", right: "RIGHT JOIN", cross: "CROSS JOIN"}.fetch(node.kind)
          operator = "NATURAL #{operator}" if node.natural
          text = "#{source(node.left, parameters: parameters)} #{operator} #{source(node.right, parameters: parameters)}"
          text += " ON #{expression(node.condition, parameters: parameters)}" if node.condition
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

# frozen_string_literal: true

module H2
  module SQL
    ColumnBinding = Data.define(:name, :qualifier, :type, :key)

    class Scope
      attr_reader :bindings, :visible, :qualifiers

      def self.for_columns(columns, qualifiers = [])
        bindings = columns.map { ColumnBinding.new(it.name, qualifiers.first, it.type, it.name) }
        new(bindings, qualifiers: qualifiers.compact)
      end

      def initialize(bindings, visible: bindings, qualifiers: bindings.map(&:qualifier).compact.uniq, parent: nil)
        @bindings = bindings.freeze
        @visible = visible.freeze
        @qualifiers = qualifiers.freeze
        @resolved = {}
        @parent = parent
      end

      def resolve(reference)
        @resolved.fetch(reference) do
          candidates = if reference.qualifier
            bindings.select { it.name == reference.name && it.qualifier == reference.qualifier }
          else
            bindings.select { it.name == reference.name }
          end
          raise Error.new(90059, "Ambiguous column #{reference.name}") if candidates.length > 1
          return @resolved[reference] = @parent.resolve(reference) if candidates.empty? && @parent
          if candidates.empty?
            raise Error.new(42122, "Column #{[reference.qualifier, reference.name].compact.join('.')} not found")
          end

          @resolved[reference] = candidates.first
        end
      end

      def local?(binding)
        bindings.include?(binding)
      end

      def star(qualifier)
        return visible unless qualifier

        raise Error.new(42122, "Cannot resolve #{qualifier}.*") unless qualifiers.include?(qualifier)

        bindings.select { it.qualifier == qualifier }
      end
    end
  end
end

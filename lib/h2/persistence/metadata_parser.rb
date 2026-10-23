# frozen_string_literal: true

module H2
  module Persistence
    UserDefinition = Data.define(:name, :salt, :hash, :admin)
    IndexDefinition = Data.define(:name, :table, :columns, :sort_types, :unique, :primary)
    ConstraintDefinition = Data.define(:name, :table, :columns, :primary, :index_name)
    SettingDefinition = Data.define(:name, :value)

    class MetadataParser < SQL::Parser
      private

      def parse_statement
        if accept("SET")
          name = identifier
          unsupported unless name == "CREATE_BUILD"
          return SettingDefinition.new(name, positive_integer)
        elsif accept("ALTER")
          expect("TABLE")
          table = table_name
          expect("ADD")
          expect("CONSTRAINT")
          name = table_name
          primary = accept("PRIMARY")
          primary ? expect("KEY") : expect("UNIQUE")
          distinct_nulls unless primary
          columns = parenthesized_identifiers
          index = accept("INDEX") ? table_name : nil
          return ConstraintDefinition.new(name, table, columns.freeze, primary, index)
        end
        super
      end

      def create
        accept("CACHED") || accept("MEMORY")
        return super if keyword?("TABLE")
        if accept("USER")
          if accept("IF")
            expect("NOT")
            expect("EXISTS")
          end
          name = identifier
          expect("SALT")
          salt = hex_literal
          expect("HASH")
          hash = hex_literal
          return UserDefinition.new(name, salt, hash, accept("ADMIN"))
        end
        primary = accept("PRIMARY")
        unique = primary || accept("UNIQUE")
        if primary
          expect("KEY")
        else
          distinct_nulls if unique
          expect("INDEX")
        end
        name = table_name
        expect("ON")
        table = table_name
        expect("(")
        columns, sorts = [], []
        loop do
          columns << identifier
          descending = accept("DESC")
          accept("ASC") unless descending
          flags = descending ? 1 : 0
          if accept("NULLS")
            if accept("FIRST")
              flags |= 2
            else
              expect("LAST")
              flags |= 4
            end
          elsif !primary
            flags |= descending ? 4 : 2
          end
          sorts << flags
          break unless accept(",")
        end
        expect(")")
        IndexDefinition.new(name, table, columns.freeze, sorts.freeze, unique, primary)
      end

      def row_type
        if keyword?("(") && @tokens[@position + 1]&.value == ")"
          take
          take
          return RowType.new([])
        end
        super
      end

      def lob_type(name)
        if keyword?('(') && @tokens[@position + 1]&.value == 0 && @tokens[@position + 2]&.value == ')'
          3.times { take }
          return Type.new(name: name,precision: 0,scale: 0,declared_precision: 0)
        end
        super
      end

      def distinct_nulls
        expect("DISTINCT") if accept("NULLS")
      end

      def hex_literal
        token = take
        unless token.kind == :literal && token.value.is_a?(String) && token.value.match?(/\A(?:[0-9a-fA-F]{2})*\z/)
          syntax("hexadecimal string")
        end
        [token.value].pack("H*").freeze
      end
    end
  end
end

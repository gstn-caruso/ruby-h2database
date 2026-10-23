# frozen_string_literal: true

require_relative "../mvstore"
require_relative "sql_writer"
require_relative "metadata_parser"
require_relative "value_adapter"

module H2
  module Persistence
    Record = Data.define(:id, :kind, :sql)
    StoredIndex = Data.define(:id, :statement, :physical)
    Definition = Data.define(:id, :statement, :indexes, :constraints, :record_ids)

    class Catalog
      attr_reader :tables, :path

      def self.file_name(path)
        expanded = File.expand_path(path)
        expanded.end_with?(".mv.db") ? expanded : "#{expanded}.mv.db"
      end

      def initialize(path, user:, password:, read_only:, compression:)
        @path = self.class.file_name(path)
        @store = MVStore::Store.open(@path, read_only: read_only, compression: compression)
        @transactions = MVStore::TransactionStore.new(@store, recover: false)
        @records, @definitions = {}, {}
        if @store.has_map?("table.0")
          load_metadata
          authenticate(user.upcase, password)
          @transactions.recover! unless read_only
          load_metadata
        else
          unless @store.version.zero? && !read_only
            raise Error.new(50100, "File does not contain a supported SQL catalog")
          end
          bootstrap(user.upcase, password)
          load_metadata
        end
        @tables = load_tables
      rescue MVStore::Error => error
        abort
        raise sql_error(error)
      rescue Exception
        abort
        raise
      end

      def read_only?
        @store.read_only?
      end

      def closed?
        @store.closed?
      end

      def publish(changes)
        raise Error.new(90097, "Database is read-only") if read_only?

        records, definitions = @records.dup, @definitions.dup
        planned = changes.to_h do |name, table|
          if table.nil?
            definition = definitions.delete(name)
            definition&.record_ids&.each { records.delete(it) }
            [name, nil]
          else
            definition = definitions[name] ||= create_definition(table, records)
            [name, assign_row_ids(table, definition)]
          end
        end
        @transactions.transaction do |tx|
          planned.each do |name, table|
            definition = table ? definitions.fetch(name) : @definitions[name]
            next unless definition

            if table
              write_table(tx, table, definition)
            else
              tx.open_map("table.#{definition.id}").clear
              definition.indexes.select(&:physical).each { tx.open_map("index.#{it.id}").clear }
            end
          end
          sync_map(tx.open_map("table.0"), records.values.map { [it.id, metadata_row(it)] })
        end
        @records, @definitions = records, definitions
        @tables = @tables.merge(planned).reject { |_name, table| table.nil? }.freeze
        planned
      rescue MVStore::Error => error
        raise sql_error(error)
      end

      def close
        @transactions&.close
        @store&.close
      rescue MVStore::Error => error
        raise sql_error(error)
      ensure
        @store&.close_immediately
      end

      def abort
        @store&.close_immediately
        @transactions&.close
      end

      private

      def sql_error(error)
        code = {1 => 90028, 2 => 90028, 4 => 90098, 5 => 50100, 6 => 90030, 7 => 90020,
          9 => 90030, 100 => 90030, 101 => 50200, 102 => 90129, 103 => 90098, 104 => 90129, 105 => 40001}.fetch(error.code, 50000)
        Error.new(code, error.message)
      end

      def row_type(width)
        MVStore::Codecs::RowType.new(column_count: width, sort_types: Array.new(width, 0), store_keys: false)
      end

      def integer(value)
        MVStore::Value.new(:integer, value)
      end

      def metadata_row(record)
        MVStore::SearchRow.new(0, [integer(record.id), integer(0), integer(record.kind), MVStore::Value.new(:varchar, record.sql)])
      end

      def password_hash(user, password, force: false)
        return "".b if !force && user.empty? && password.empty?

        bytes = MVStore::Codecs::STRING.units(user + "@").pack("n*") + MVStore::Codecs::STRING.units(password).pack("n*")
        Digest::SHA256.digest(bytes)
      ensure
        bytes&.replace("\0" * bytes.bytesize)
      end

      def bootstrap(user, password)
        key = password_hash(user, password)
        salt = key.empty? ? "".b : Random.urandom(8)
        hash = key.empty? ? "".b : Digest::SHA256.digest(key + salt)
        user_sql = "CREATE USER IF NOT EXISTS #{SQLWriter.identifier(user)} SALT '#{salt.unpack1('H*')}' HASH '#{hash.unpack1('H*')}' ADMIN"
        initial = [Record.new(1, 6, "SET CREATE_BUILD 259"), Record.new(2, 2, user_sql)]
        @transactions.transaction do |tx|
          meta = tx.open_map("table.0", key_type: :long, value_type: row_type(4))
          initial.each { meta[it.id] = metadata_row(it) }
        end
      end

      def parse_metadata(record)
        parser = MetadataParser.new(record.sql)
        statement = parser.parse
        raise Error.new(50100, "Saved metadata contains unbound parameters") unless parser.parameter_count.zero?

        statement
      rescue Error => error
        raise unless [42000, 42001, 90079].include?(error.code)

        raise Error.new(50100, "Saved SQL metadata is not supported: #{error.message}")
      end

      def load_metadata
        @records = @transactions.transaction do |tx|
          tx.open_map("table.0").to_h.transform_values do |row|
            values = row.values.map(&:to_ruby)
            unless values.length == 4 && values[0].is_a?(Integer) && values[2].is_a?(Integer) && values[3].is_a?(String)
              raise Error.new(90030, "Invalid SQL catalog record")
            end
            Record.new(values[0], values[2], values[3])
          end
        end
        @parsed = @records.transform_values { parse_metadata(it) }
        @records.each do |id, record|
          klass = {0 => SQL::CreateTable, 1 => IndexDefinition, 2 => UserDefinition, 5 => ConstraintDefinition, 6 => SettingDefinition}[record.kind]
          unless record.id == id && klass && @parsed[id].is_a?(klass)
            raise Error.new(50100, "SQL catalog object type #{record.kind} is not supported")
          end
        end
        @last_object_id = [@records.keys.max || 0, *@store.map_names.filter_map { /\A(?:table|index)\.(\d+)\z/.match(it)&.[](1)&.to_i }].max
        @definitions = {}
        @records.values.select { it.kind == 0 }.each do |record|
          statement = @parsed.fetch(record.id)
          indexes = @records.values.select { it.kind == 1 && @parsed[it.id].table == statement.name }.map do |index|
            StoredIndex.new(index.id, @parsed.fetch(index.id), @store.has_map?("index.#{index.id}"))
          end
          constraints = @records.values.select { it.kind == 5 && @parsed[it.id].table == statement.name }.map { @parsed.fetch(it.id) }
          ids = [record.id] + indexes.map(&:id) + @records.values.select { it.kind == 5 && @parsed[it.id].table == statement.name }.map(&:id)
          raise Error.new(90030, "Duplicate stored table") if @definitions.key?(statement.name)

          @definitions[statement.name] = Definition.new(record.id, statement, indexes.freeze, constraints.freeze, ids.freeze)
        end
        schema = @definitions.to_h do |name, definition|
          [name, Table.new(name, definition.statement.columns, definition.statement.keys).seal]
        end
        schema.each_value do |table|
          table.columns.each do |column|
            next unless column.default

            SQL::Evaluator.new([], queries: SQL::Queries.new(schema, [])).validate(column.default)
          end
        end
      end

      def authenticate(user, password)
        definition = @parsed.values.find { it.is_a?(UserDefinition) && it.name == user }
        key = password_hash(user, password)
        empty = key.empty?
        key = password_hash(user, password, force: true) if empty
        expected = definition && Digest::SHA256.digest(key + definition.salt)
        valid = definition && ((empty && definition.hash.empty?) ||
          (expected.bytesize == definition.hash.bytesize && expected.bytes.zip(definition.hash.bytes).reduce(0) { |sum, (a, b)| sum | (a ^ b) }.zero?))
        raise Error.new(28000, "Wrong user name or password") unless valid
        raise Error.new(90040, "SQL file access currently requires an administrator") unless definition.admin
      end

      def load_tables
        @transactions.transaction do |tx|
          @definitions.to_h do |name, definition|
            statement = definition.statement
            columns = statement.columns.map do |column|
              default = column.default
              if default && SQL::Evaluator.new([]).contains_subquery?(default)
                default = SQL::CapturedExpression.new(default, [].freeze)
              end
              column.with(default: default)
            end
            keys = statement.keys + definition.constraints.map { Key.new(it.columns, it.primary) } +
              definition.indexes.select { it.statement.unique }.map { Key.new(it.statement.columns, it.statement.primary) }
            table = Table.new(name, columns, keys.uniq)
            stored = tx.open_map("table.#{definition.id}")
            stored.each do |id, row|
              unless row.is_a?(MVStore::SearchRow) && row.values.length == columns.length
                raise Error.new(90030, "Stored table row has the wrong width")
              end
              values = columns.each_with_index.to_h { |column, index| [column.name, ValueAdapter.decode(row.values[index], column.type)] }
              result = table.convert_row(values)
              table.rows << result
              table.assign_row_id(result, id)
            end
            table.validate_constraints
            [name, table.seal]
          end.freeze
        end
      end

      def next_object_id
        @last_object_id += 1
      end

      def create_definition(table, records)
        id = next_object_id
        create_sql = SQLWriter.create_table(table)
        records[id] = Record.new(id, 0, create_sql)
        statement = MetadataParser.new(create_sql).parse
        indexes, constraints, ids = [], [], [id]
        table.keys.each do |key|
          index_id, constraint_id = next_object_id, next_object_id
          index_name = "#{key.primary ? 'PRIMARY_KEY' : 'UNIQUE_INDEX'}_#{index_id.to_s(16).upcase}"
          constraint_name = "CONSTRAINT_#{constraint_id.to_s(16).upcase}"
          index = IndexDefinition.new(index_name, table.name, key.columns, Array.new(key.columns.length, key.primary ? 0 : 2).freeze, true, key.primary)
          physical = !(key.primary && key.columns.length == 1 && Type::INTEGER_LIMITS.key?(table.columns.find { it.name == key.columns.first }.type.name))
          indexes << StoredIndex.new(index_id, index, physical)
          constraint = ConstraintDefinition.new(constraint_name, table.name, key.columns, key.primary, index_name)
          constraints << constraint
          names = key.columns.map { SQLWriter.identifier(it) }.join(", ")
          index_sql = "CREATE #{key.primary ? 'PRIMARY KEY' : 'UNIQUE INDEX'} #{SQLWriter.table_name(index_name)} ON #{SQLWriter.table_name(table.name)}(#{names})"
          constraint_sql = "ALTER TABLE #{SQLWriter.table_name(table.name)} ADD CONSTRAINT #{SQLWriter.table_name(constraint_name)} #{key.primary ? 'PRIMARY KEY' : 'UNIQUE'}(#{names}) INDEX #{SQLWriter.table_name(index_name)}"
          records[index_id] = Record.new(index_id, 1, index_sql)
          records[constraint_id] = Record.new(constraint_id, 5, constraint_sql)
          ids.concat([index_id, constraint_id])
        end
        Definition.new(id, statement, indexes.freeze, constraints.freeze, ids.freeze)
      end

      def main_column(table, definition)
        primary = definition.indexes.find { it.statement.primary && !it.physical }
        primary && table.columns.index { it.name == primary.statement.columns.first }
      end

      def assign_row_ids(table, definition)
        main = main_column(table, definition)
        last = table.last_row_id
        ids = {}.compare_by_identity
        table.rows.each do |row|
          id = if main
            row.fetch(table.columns[main].name)
          else
            table.row_id(row) || (last += 1)
          end
          last = [last, id].max
          ids[row] = id
        end
        Table.new(table.name, table.columns, table.keys, table.rows, row_ids: ids, last_row_id: last).seal
      end

      def write_table(tx, table, definition)
        data = tx.open_map("table.#{definition.id}", key_type: :long, value_type: row_type(table.columns.length))
        rows = table.rows.map do |row|
          values = table.columns.map { ValueAdapter.encode(row.fetch(it.name), it.type) }
          [table.row_id(row), MVStore::SearchRow.new(0, values)]
        end
        sync_map(data, rows)
        definition.indexes.select(&:physical).each do |index|
          positions = index.statement.columns.map { |name| table.columns.index { it.name == name } || raise(Error.new(90030, "Unknown index column")) }
          key_type = MVStore::Codecs::RowType.new(column_count: table.columns.length, sort_types: index.statement.sort_types, indexes: positions, store_keys: true)
          null_type = MVStore::Codecs::MetaType::STATELESS.fetch("org.h2.mvstore.db.NullValueDataType")
          map = tx.open_map("index.#{index.id}", key_type: key_type, value_type: null_type)
          entries = rows.map do |id, row|
            values = Array.new(table.columns.length)
            positions.each { values[it] = row.values[it] }
            [MVStore::SearchRow.new(id, values), MVStore::Value.new(:null, nil)]
          end
          sync_map(map, entries)
        end
      end

      def sync_map(map, desired)
        codec = map.raw_map.key_type
        desired = desired.sort { |left, right| codec.compare(left.first, right.first) }
        existing = map.to_a
        left = right = 0
        while left < existing.length || right < desired.length
          comparison = if left >= existing.length
            1
          elsif right >= desired.length
            -1
          else
            codec.compare(existing[left].first, desired[right].first)
          end
          if comparison.negative?
            map.delete(existing[left].first)
            left += 1
          elsif comparison.positive?
            map[desired[right].first] = desired[right].last
            right += 1
          else
            map[desired[right].first] = desired[right].last unless existing[left].last == desired[right].last
            left += 1
            right += 1
          end
        end
      end
    end
  end
end

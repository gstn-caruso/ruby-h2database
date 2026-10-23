# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class ByteArrayType
        include Type

        def copy(bytes)
          raise ArgumentError, "Expected binary String" unless bytes.is_a?(String)

          bytes.b.freeze
        end

        def compare(left, right)
          left.b <=> right.b
        end

        def write(buffer, bytes)
          DataUtils.write_var_int(buffer, bytes.bytesize)
          buffer.write(bytes)
        end

        def read(buffer)
          buffer.read(DataUtils.read_var_int(buffer)).freeze
        end
      end

      class NullType
        include Type

        def copy(value)
          raise ArgumentError, "Expected SQL NULL" unless value.is_a?(Value) && value.type == :null

          value
        end

        def compare(_left, _right)
          0
        end

        def write(_buffer, value)
          copy(value)
        end

        def read(_buffer)
          Value.new(:null, nil)
        end
      end

      class MetaType
        include Type
        STATELESS = {"org.h2.mvstore.type.StringDataType" => STRING, "org.h2.mvstore.type.LongDataType" => LONG,
          "org.h2.mvstore.type.ByteArrayDataType" => ByteArrayType.new.freeze,
          "org.h2.mvstore.db.NullValueDataType" => NullType.new.freeze, "org.h2.mvstore.type.ObjectDataType" => OBJECT,
          "org.h2.mvstore.db.LobStorageMap$BlobMeta$Type" => BLOB_META,
          "org.h2.mvstore.db.LobStorageMap$BlobReference$Type" => BLOB_REFERENCE}.freeze

        def copy(codec)
          raise ArgumentError, "Expected a storage codec" unless codec.is_a?(Type)

          codec
        end

        def compare(_left, _right)
          raise Error.new(5, "Type descriptors cannot be used as map keys")
        end

        def write(buffer, codec)
          if (name = STATELESS.key(codec))
            STRING.write(buffer, name)
          elsif codec.is_a?(RowType)
            STRING.write(buffer, "org.h2.mvstore.db.RowDataType$Factory")
            DataUtils.write_var_int(buffer, codec.column_count)
            write_array(buffer, codec.sort_types)
            write_array(buffer, codec.indexes)
            buffer.put_byte(codec.store_keys ? 1 : 0)
          elsif codec.is_a?(VersionedType)
            STRING.write(buffer, "org.h2.mvstore.tx.VersionedValueType$Factory")
            write(buffer, codec.value_type)
          elsif codec == VALUE
            STRING.write(buffer, "org.h2.mvstore.db.ValueDataType$Factory")
            buffer.write("\x00\x00\x00\x01".b)
          else
            raise Error.new(5, "Unregistered storage codec")
          end
        end

        def read(buffer)
          name = STRING.read(buffer)
          return STATELESS[name] if STATELESS.key?(name)

          case name
          when "org.h2.mvstore.db.RowDataType$Factory"
            count = DataUtils.read_var_int(buffer)
            raise Error.new(6, "Invalid row column count") unless (0..16_384).cover?(count)

            sorts, indexes, keys = read_array(buffer), read_array(buffer), buffer.byte
            raise Error.new(6, "Invalid row key marker") unless [0, 1].include?(keys)

            RowType.new(column_count: count, sort_types: sorts, indexes: indexes, store_keys: keys == 1)
          when "org.h2.mvstore.tx.VersionedValueType$Factory" then VersionedType.new(read(buffer))
          when "org.h2.mvstore.db.ValueDataType$Factory"
            sorts, count, indexes, keys = read_array(buffer), DataUtils.read_var_int(buffer), read_array(buffer), buffer.byte
            unless sorts.nil? && count.zero? && indexes.nil? && keys == 1
              raise Error.new(5, "Legacy stateful SQL value codec has not been ported")
            end
            VALUE
          else raise Error.new(5, "Unknown storage codec #{name}")
          end
        rescue ArgumentError => error
          raise Error.new(6, "Invalid storage descriptor: #{error.message}")
        end

        private

        def write_array(buffer, array)
          DataUtils.write_var_int(buffer, array ? array.length + 1 : 0)
          array&.each { DataUtils.write_var_int(buffer, it) }
        end

        def read_array(buffer)
          count = DataUtils.read_var_int(buffer)
          return nil if count.zero?
          raise Error.new(6, "Invalid descriptor array length") unless count.positive? && count - 1 <= buffer.remaining

          Array.new(count - 1) { DataUtils.read_var_int(buffer) }
        end
      end

      META = MetaType.new.freeze
      BYTES = MetaType::STATELESS.fetch("org.h2.mvstore.type.ByteArrayDataType")
      NULL = MetaType::STATELESS.fetch("org.h2.mvstore.db.NullValueDataType")
    end
  end
end

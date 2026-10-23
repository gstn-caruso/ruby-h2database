# frozen_string_literal: true

module H2
  module MVStore
    module Codecs
      class BlobMetadataType
        include Type

        def copy(value)
          raise ArgumentError, "Expected LOB metadata" unless value.is_a?(BlobMetadata)

          value
        end

        def compare(_left, _right)
          raise Error.new(5, "LOB metadata cannot be used as map keys")
        end

        def write(buffer, value)
          copy(value)
          DataUtils.write_var_int(buffer,value.stream_id.bytesize)
          buffer.write(value.stream_id)
          DataUtils.write_var_int(buffer,value.table_id)
          DataUtils.write_var_long(buffer,value.byte_count)
          buffer.write([value.content_hash].pack('q>'))
        end

        def read(buffer)
          id = buffer.read(DataUtils.read_var_int(buffer))
          BlobMetadata.new(id,DataUtils.read_var_int(buffer),DataUtils.read_var_long(buffer),buffer.read(8).unpack1('q>'))
        end
      end

      class BlobReferenceType
        include Type

        def copy(value)
          raise ArgumentError, "Expected LOB block reference" unless value.is_a?(BlobReference)

          value
        end

        def compare(left, right)
          return 0 if left.equal?(right)
          return 1 if left.nil?
          return -1 if right.nil?

          result = left.stream_id.bytesize <=> right.stream_id.bytesize
          result = left.stream_id.unpack('c*') <=> right.stream_id.unpack('c*') if result.zero?
          result.zero? ? left.lob_id <=> right.lob_id : result
        end

        def write(buffer, value)
          copy(value)
          DataUtils.write_var_int(buffer,value.stream_id.bytesize)
          buffer.write(value.stream_id)
          DataUtils.write_var_long(buffer,value.lob_id)
        end

        def read(buffer)
          BlobReference.new(buffer.read(DataUtils.read_var_int(buffer)),DataUtils.read_var_long(buffer))
        end
      end

      BLOB_META = BlobMetadataType.new.freeze
      BLOB_REFERENCE = BlobReferenceType.new.freeze
    end
  end
end

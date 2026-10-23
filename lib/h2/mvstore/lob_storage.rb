# frozen_string_literal: true

require 'stringio'
require 'monitor'

module H2
  module MVStore
    class LobStorage
      TEMPORARY_TABLES = [-1,-2,-3].freeze
      Removal = Data.define(:version, :table_id, :lob_id, :immediate)
      attr_reader :store, :max_in_place, :next_lob_id

      def self.open(store, **options)
        storage = new(store,**options)
        return storage unless block_given?

        begin
          yield storage
        ensure
          storage.close
        end
      end

      def initialize(store, max_in_place: 256)
        unless max_in_place.is_a?(Integer) && (0...(1 << 31)).cover?(max_in_place)
          raise ArgumentError, "Invalid inline LOB limit"
        end
        @store, @max_in_place = store, max_in_place
        @monitor = Monitor.new
        @closed = @closing = false
        @pending, @readers = [], {}
        store.claim_lobs(self)
        @metadata = open_map('lobMap',:long,:blob_meta)
        @temporary = open_map('tempLobMap',:long,:bytes)
        @references = open_map('lobRef',:blob_reference,:null)
        @blocks = open_map('lobData',:long,:bytes)
        @streams = StreamStore.new(@blocks)
        key = @blocks.map(&:first).max
        @streams.next_key = key == (1 << 63) - 1 ? -(1 << 63) : key + 1 if key
        @next_lob_id = [1,(@metadata.map(&:first).max || 0) + 1,(@temporary.map(&:first).max || 0) + 1].max
      rescue Exception
        @closed = true
        store.release_lobs(self)
        raise
      end

      def read_only? = store.read_only?
      def closed? = @closed || store.closed?
      def pending_count = @monitor.synchronize { @pending.length }

      def create_blob(input, max_length: -1)
        validate_length(max_length)
        synchronize do
          if max_length >= 0 && max_length <= max_in_place
            bytes = read_all(LimitedInput.new(input,max_length))
            next Value.new(:blob,bytes)
          end
          store.check_writable
          input = LimitedInput.new(input,max_length) if max_length >= 0
          create_external(input,:blob)
        end
      end

      def create_clob(input, max_length: -1)
        validate_length(max_length)
        synchronize do
          input = StringIO.new(input) if input.is_a?(String)
          units = Utf16Input.new(input)
          if max_length >= 0 && max_length * 3 <= max_in_place
            text = max_length.zero? ? ''.b : (units.read_units(max_length) || ''.b)
            bytes = text.force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8,invalid: :replace,undef: :replace,replace: '?')
            next Value.new(:clob,InlineClob.new(bytes,text.bytesize / 2))
          end
          store.check_writable
          encoded = Utf8LobInput.new(units,max_length.negative? ? (1 << 63) - 1 : max_length)
          create_external(encoded,:clob) { encoded.characters }
        end
      end

      def copy_lob(value, table_id:)
        validate_value(value)
        validate_table(table_id)
        synchronize do
          next value unless value.data.is_a?(LobReference)

          store.check_writable
          source = value.data
          id = stream_id(source.lob_id,source.table_id)
          lob_id = allocate_id
          if temporary_table?(table_id)
            @temporary[lob_id] = id
          else
            @metadata[lob_id] = BlobMetadata.new(id,table_id,source.characters || source.octets,0)
          end
          @references[BlobReference.new(id,lob_id)] = Value.new(:null,nil)
          Value.new(value.type,LobReference.new(table_id,lob_id,source.octets,source.characters))
        end
      end

      def get_input_stream(lob_id, table_id: nil)
        Codecs::LONG.copy(lob_id)
        validate_table(table_id) unless table_id.nil?
        synchronize do
          id = stream_id(lob_id,table_id)
          reader = LobReader.new(self,@streams.get(id))
          @readers[reader] = store.version
          reader
        end
      end

      def open(value)
        validate_value(value)
        reader = if value.data.is_a?(LobReference)
          get_input_stream(value.data.lob_id,table_id: value.data.table_id)
        else
          synchronize { StringIO.new(value.type == :blob ? value.data : value.data.bytes) }
        end
        return reader unless block_given?

        begin
          yield reader
        ensure
          reader.close
        end
      end

      def remove_lob(value)
        validate_value(value)
        synchronize do
          next unless value.data.is_a?(LobReference)

          store.check_writable
          @pending << Removal.new(store.version,value.data.table_id,value.data.lob_id,false)
        end
        nil
      end

      def remove_all_for_table(table_id)
        validate_table(table_id)
        return nil if store.closed?

        synchronize do
          store.check_writable
          keys = temporary_table?(table_id) ? @temporary.map(&:first) : @metadata.filter_map { |id,meta| id if meta.table_id == table_id }
          keys.each do |id|
            if @readers.empty?
              remove_reference(table_id,id)
            else
              @pending << Removal.new(store.version,table_id,id,true)
            end
          end
        end
        nil
      end

      def cleanup(oldest_version: store.version)
        raise ArgumentError, "Invalid cleanup version" unless oldest_version.is_a?(Integer) && oldest_version >= 0

        synchronize do
          store.check_writable
          oldest_version = [oldest_version,*@readers.values].min
          ready, @pending = @pending.partition { it.immediate ? @readers.empty? : it.version < oldest_version }
          ready.each { remove_reference(it.table_id,it.lob_id) }
        end
        nil
      end

      def with_reader(reader)
        synchronize do
          raise Error.new(4, "LOB reader is closed") unless @readers.key?(reader)

          yield
        end
      end

      def release_reader(reader)
        @monitor.synchronize do
          yield if block_given?
          @readers.delete(reader)
          cleanup unless @closing || closed? || read_only?
        end
      end

      def close
        @monitor.synchronize do
          return nil if @closed

          @closing = true
          @readers.keys.each(&:close)
          unless store.closed? || read_only?
            remove_all_for_table(-1)
            cleanup(oldest_version: store.version + 1)
          end
          @closed = true
        ensure
          @closing = false
          @closed = true
          store.release_lobs(self)
        end
        nil
      end

      private

      def synchronize(&operation)
        @monitor.synchronize do
          store.synchronize do
            store.check_open
            raise Error.new(4, "LOB storage is closed") if @closed

            operation.call
          end
        end
      end

      def open_map(name, key, value)
        store.has_map?(name) ? store.open_map(name,key_type: key,value_type: value) : store.open_registered_map(name,key_type: key,value_type: value)
      end

      def validate_length(length)
        raise ArgumentError, "Invalid LOB length" unless length.is_a?(Integer) && (-1...(1 << 63)).cover?(length)
      end

      def validate_table(id)
        raise ArgumentError, "Invalid LOB table id" unless id.is_a?(Integer) && (-(1 << 31)...(1 << 31)).cover?(id)
      end

      def validate_value(value)
        raise ArgumentError, "Expected a LOB storage value" unless value.is_a?(Value) && [:blob,:clob].include?(value.type)
      end

      def temporary_table?(id) = TEMPORARY_TABLES.include?(id)

      def allocate_id
        raise RangeError, "LOB identifiers are exhausted" if @next_lob_id > (1 << 63) - 1

        id = @next_lob_id
        @next_lob_id += 1
        id
      end

      def create_external(input, type)
        id = @streams.put(input)
        begin
          lob_id = allocate_id
        rescue RangeError
          @streams.remove(id)
          raise
        end
        @temporary[lob_id] = id
        @references[BlobReference.new(id,lob_id)] = Value.new(:null,nil)
        Value.new(type,LobReference.new(-2,lob_id,@streams.length(id),block_given? ? yield : nil))
      end

      def read_all(input)
        bytes = +''.b
        loop do
          chunk = input.read(4096)
          break if chunk.nil? || chunk.empty?

          bytes << chunk.b
        end
        bytes
      end

      def stream_id(lob_id, table_id)
        id = if table_id.nil?
          @temporary[lob_id] || @metadata[lob_id]&.stream_id
        elsif temporary_table?(table_id)
          @temporary[lob_id]
        else
          @metadata[lob_id]&.stream_id
        end
        id || raise(Error.new(50, "LOB #{lob_id} not found"))
      end

      def remove_reference(table_id, lob_id)
        id = temporary_table?(table_id) ? @temporary.delete(lob_id) : @metadata.delete(lob_id)&.stream_id
        return unless id

        @references.delete(BlobReference.new(id,lob_id))
        remaining = @references.ceiling_key(BlobReference.new(id,-(1 << 63)))
        @streams.remove(id) unless remaining && remaining.stream_id == id
      end
    end
  end
end

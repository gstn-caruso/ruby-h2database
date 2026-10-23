# frozen_string_literal: true

module H2
  module Persistence
    class LobReferences
      JOURNAL = 'ruby.lobCleanup'

      def initialize(store)
        @store = store
        @sources, @decoded = {}, {}
      end

      def encode(value, table_id:, previous: nil)
        type = value.is_a?(BlobValue) ? :blob : :clob
        if previous && previous.type == type && decode(previous) == value
          return previous
        end
        if value.bytes.bytesize <= 256
          return MVStore::Value.new(type,type == :blob ? value.bytes : MVStore::InlineClob.new(value.bytes,value.characters))
        end

        source = @sources[value]
        unless source
          input = StringIO.new(type == :blob ? value.bytes : value.to_s)
          source = type == :blob ? storage.create_blob(input,max_length: value.precision) : storage.create_clob(input,max_length: value.precision)
        end
        saved = storage.copy_lob(source,table_id: table_id)
        track(saved)
        storage.remove_lob(source) if source.data.table_id == -2
        @sources[value] = saved
        @decoded[saved.data.lob_id] = value
        saved
      end

      def decode(value)
        data = value.data
        unless data.is_a?(MVStore::LobReference)
          return value.type == :blob ? BlobValue.new(data) : ClobValue.new(data.bytes,data.characters)
        end
        decoded = @decoded[data.lob_id] ||= storage.open(value) do |reader|
          bytes = reader.read
          value.type == :blob ? BlobValue.new(bytes) : ClobValue.new(bytes,data.characters)
        end
        @sources[decoded] = value
        decoded
      end

      def track(value)
        references(value) { |lob| journal[lob.data.lob_id] = lob }
      end

      def cleanup
        return if @store.read_only? || @store.closed?
        return unless @journal || @store.has_map?(JOURNAL) || (@store.has_map?('tempLobMap') && @store.open_map('tempLobMap').size.positive?)

        used = {}
        @store.map_names.each do |name|
          next unless name.match?(/\A(?:(?:table|index)\.\d+|undoLog\.\d+)\z/)

          @store.open_map(name).each do |key,value|
            references(key) { used[it.data.lob_id] = true }
            references(value) { used[it.data.lob_id] = true }
          end
        end
        if @journal || @store.has_map?(JOURNAL)
          journal.each { |id,value| storage.remove_lob(value) unless used[id] }
          journal.clear
        end
        if @store.has_map?('tempLobMap')
          @store.open_map('tempLobMap').each do |id,stream|
            next if used[id]

            storage.remove_lob(MVStore::Value.new(:blob,MVStore::LobReference.new(-2,id,MVStore::StreamIdentifier.new(stream).length,nil)))
          end
        end
        @storage&.cleanup(oldest_version: @store.version + 1)
        @sources.delete_if { |_value,lob| !used[lob.data.lob_id] }
        @decoded.delete_if { |id,_value| !used[id] }
        @store.commit
      rescue MVStore::Error
        @store.close_immediately
        raise
      end

      def close
        cleanup
        @storage&.close
      end

      private

      def storage = @storage ||= MVStore::LobStorage.new(@store)

      def journal
        @journal ||= @store.has_map?(JOURNAL) ? @store.open_map(JOURNAL) : @store.open_registered_map(JOURNAL,key_type: :long,value_type: :value)
      end

      def references(value, &block)
        case value
        when MVStore::Value
          if value.data.is_a?(MVStore::LobReference)
            yield value
          elsif [:array,:row].include?(value.type)
            value.data.each { references(it,&block) }
          end
        when MVStore::SearchRow
          value.values.each { references(it,&block) }
        when MVStore::VersionedValue
          references(value.current,&block)
          references(value.committed,&block)
        when MVStore::UndoRecord
          references(value.key,&block)
          references(value.old_value,&block)
        end
      end
    end
  end
end

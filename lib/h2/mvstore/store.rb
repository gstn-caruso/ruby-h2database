# frozen_string_literal: true

require "monitor"
require "digest"

module H2
  module MVStore
    class Store
      def self.open(path, **options)
        store = new(path, **options)
        return store unless block_given?

        begin
          yield store
        ensure
          store.close
        end
      end

      def initialize(path, read_only: false, compression: :none, keys_per_page: 48)
        raise ArgumentError, "At least two keys per page are required" unless keys_per_page.is_a?(Integer) && keys_per_page >= 2
        raise ArgumentError, "Unknown compression" unless [:none, :fast, :high].include?(compression)

        @mutex = Monitor.new
        @read_only, @compression, @keys_per_page = read_only, compression, keys_per_page
        @maps = {}
        @closed = false
        @storage = FileStorage.new(path, read_only: read_only)
        if @storage.size.zero?
          raise Error.new(6, "Empty read-only file") if read_only

          initial = {"H" => 2, "blockSize" => 4096, "created" => (Time.now.to_r * 1000).to_i, "format" => 3}
          bytes = DataUtils.checksummed_map(initial, size: 4096)
          @storage.write_at(0, bytes * 2)
          @storage.sync
          @storage.sync_parent
        end
        reload_metadata
        if !read_only && DataUtils.hex(@reader.header, "format", 1) != 3
          raise Error.new(5, "Unsupported MVStore write format")
        end
        @meta_dirty = @reader.last_chunk.nil?
        publish_header(clean: false) unless read_only
      rescue Exception
        @storage&.close
        raise
      end

      def synchronize(&block)
        @mutex.synchronize(&block)
      end

      def check_open
        raise Error.new(4, "MVStore is closed") if @closed
      end

      def check_writable
        check_open
        raise Error.new(2, "MVStore is read-only") if @read_only
      end

      def header
        @reader.header
      end

      def chunks
        @reader.chunks
      end

      def layout
        @reader.layout
      end

      def version
        @reader.version
      end

      def map_names
        synchronize do
          check_open
          @metadata.keys.filter_map { it.delete_prefix("name.") if it.start_with?("name.") }.freeze
        end
      end

      def read_only?
        @read_only
      end

      def has_map?(name)
        synchronize { check_open; @metadata.key?("name.#{name}") }
      end

      def find_map(id)
        synchronize do
          check_open
          description = @metadata["map.#{id.to_s(16)}"]
          open_map(DataUtils.parse_map(description).fetch("name")) if description
        end
      end

      def open_registered_map(name, key_type:, value_type:)
        synchronize do
          check_writable
          registry = open_map("_", key_type: :string, value_type: :meta)
          key_type, value_type = Codecs.fetch(key_type), Codecs.fetch(value_type)
          references = [key_type, value_type].map do |type|
            buffer = Buffer.new
            Codecs::META.write(buffer, type)
            reference = "ruby.#{Digest::SHA256.hexdigest(buffer.data)}"
            existing = registry[reference]
            raise Error.new(100, "Conflicting registered data type") if existing && existing != type

            registry[reference] = type unless existing
            reference
          end
          map = open_map(name, key_type: key_type, value_type: value_type)
          key = "map.#{map.id.to_s(16)}"
          values = DataUtils.parse_map(@metadata.fetch(key)).merge("key" => references[0], "val" => references[1])
          @metadata[key] = DataUtils.dump_map(values)
          @meta_dirty = true
          map
        end
      end

      def remove_map(name)
        synchronize do
          check_writable
          id = @metadata.delete("name.#{name}")
          return false unless id

          @metadata.delete("map.#{id}")
          @layout.delete("root.#{id}")
          @maps.delete(name)&.invalidate
          @meta_dirty = true
          true
        end
      end

      def claim_transactions(owner)
        synchronize do
          check_open
          if @transaction_owner && !@transaction_owner.closed?
            raise Error.new(103, "MVStore already has a transaction coordinator")
          end
          @transaction_owner = owner
        end
      end

      def claim_lobs(owner)
        synchronize do
          check_open
          raise Error.new(103, "MVStore already has a LOB manager") if @lob_owner && !@lob_owner.closed?

          @lob_owner = owner
        end
      end

      def release_lobs(owner)
        synchronize { @lob_owner = nil if @lob_owner.equal?(owner) }
      end

      def release_transactions(owner)
        synchronize { @transaction_owner = nil if @transaction_owner.equal?(owner) }
      end

      def open_map(name, key_type: nil, value_type: nil)
        name = Codecs::STRING.copy(name)
        synchronize do
          check_open
          key_type ||= @maps[name]&.key_type
          value_type ||= @maps[name]&.value_type
          id = @metadata["name.#{name}"]&.to_i(16)
          description = id ? DataUtils.parse_map(@metadata.fetch("map.#{id.to_s(16)}")) : {}
          key_type = resolve_type(description["key"], key_type)
          value_type = resolve_type(description["val"], value_type)
          if (map = @maps[name])
            unless map.key_type == key_type && map.value_type == value_type
              raise Error.new(5, "Map is already open with different data types")
            end
            return map
          end
          if id.nil?
            check_writable
            @next_map_id += 1
            id = @next_map_id
            @metadata["name.#{name}"] = id.to_s(16)
            description = {"name" => name}
            description["createVersion"] = version unless version.zero?
            @metadata["map.#{id.to_s(16)}"] = DataUtils.dump_map(description)
            @meta_dirty = true
            records = []
          else
            raise Error.new(5, "Specialized map type #{description['type']} has not been ported") if description["type"]

            root = DataUtils.hex(@layout, "root.#{id.to_s(16)}")
            records = @reader.records(root, id, key_type, value_type).to_a
          end
          @maps[name] = Map.new(self, id, name, key_type, value_type, records)
        end
      end

      def commit
        synchronize { check_writable; commit_changes }
      end

      def rollback
        synchronize do
          check_open
          @maps.delete_if do |name, map|
            if @reader.metadata.key?("name.#{name}")
              root = DataUtils.hex(@reader.layout, "root.#{map.id.to_s(16)}")
              map.restore(@reader.records(root, map.id, map.key_type, map.value_type))
              false
            else
              map.invalidate
              true
            end
          end
          @metadata = @reader.metadata.dup
          @layout = @reader.layout.dup
          @registered_types = nil
          @next_map_id = @reader.last_chunk ? DataUtils.hex(@reader.last_chunk.attributes, "map", 1) : 1
          @meta_dirty = false
          version
        end
      end

      def close
        synchronize do
          return if @closed

          begin
            unless @read_only
              commit_changes
              publish_header(clean: true)
            end
          ensure
            @closed = true
            @storage.close
          end
        end
        nil
      end

      def closed?
        @closed
      end

      def close_immediately
        synchronize do
          return if @closed

          @closed = true
          @storage.close
        end
      end

      private

      def resolve_type(registration, requested)
        registered = registration && registered_types.fetch(registration) { raise Error.new(6, "Missing registered storage type #{registration}") }
        requested = Codecs.fetch(requested) if requested
        if registered && requested && registered != requested
          raise Error.new(5, "Requested storage codec differs from the registered type")
        end
        requested || registered || Codecs::STRING
      end

      def registered_types
        if (registry = @maps["_"]) && registry.value_type == Codecs::META
          return registry.snapshot.to_h
        end

        @registered_types ||= begin
          id = DataUtils.hex(@metadata, "name._")
          raise Error.new(6, "Missing storage type registry") if id.zero?

          @reader.records(DataUtils.hex(@layout, "root.#{id.to_s(16)}"), id, Codecs::STRING, Codecs::META).to_h.freeze
        end
      end

      def reload_metadata
        @registered_types = nil
        @reader = Reader.new(@storage)
        @metadata = @reader.metadata.dup
        @layout = @reader.layout.dup
        @next_map_id = @reader.last_chunk ? DataUtils.hex(@reader.last_chunk.attributes, "map", 1) : 1
      end

      def commit_changes
        dirty = @maps.values.select(&:dirty?)
        return version unless @meta_dirty || !dirty.empty?

        id = (@reader.chunks.keys.max || 0) + 1
        raise Error.new(5, "Chunk id wraparound has not been ported") if id >= 1 << 26

        block = (@storage.size + 4095) / 4096
        created = DataUtils.hex(@reader.header, "created")
        time = [(Time.now.to_r * 1000).to_i - created, 0].max
        writer = ChunkWriter.new(id: id, version: version + 1, block: block, map_id: @next_map_id, time: time,
          keys_per_page: @keys_per_page, compression: @compression)
        layout = @layout.dup
        @reader.chunks.each_value { layout["chunk.#{it.id.to_s(16)}"] ||= it.metadata }
        dirty.each do |map|
          root = writer.write_map(map.id, map.snapshot, map.key_type, map.value_type)
          root.zero? ? layout.delete("root.#{map.id.to_s(16)}") : layout["root.#{map.id.to_s(16)}"] = root.to_s(16)
        end
        if @meta_dirty
          meta_id = DataUtils.hex(layout, "meta.id", 1)
          root = writer.write_map(meta_id, @metadata.to_a, Codecs::STRING, Codecs::STRING)
          root.zero? ? layout.delete("root.#{meta_id.to_s(16)}") : layout["root.#{meta_id.to_s(16)}"] = root.to_s(16)
        end
        bytes = writer.finish(layout)
        @storage.write_at(block * 4096, bytes)
        @storage.sync
        @reader = Reader.new(@storage)
        unless @reader.version == writer.version
          raise Error.new(6, "Committed chunk was not recoverable")
        end
        publish_header(clean: false)
        @layout = @reader.layout.dup
        @registered_types = nil
        @meta_dirty = false
        dirty.each(&:committed)
        version
      rescue Error => error
        @closed = true
        @storage.close
        raise error
      end

      def publish_header(clean:)
        values = @reader.header.merge("clean" => clean ? 1 : 0)
        if (chunk = @reader.last_chunk)
          values.merge!("chunk" => chunk.id, "block" => chunk.block, "version" => chunk.version)
        end
        bytes = DataUtils.checksummed_map(values, size: 4096)
        [0, 4096].each { @storage.write_at(it, bytes); @storage.sync }
      end
    end
  end
end

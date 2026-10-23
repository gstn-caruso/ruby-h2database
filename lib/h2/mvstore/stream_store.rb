# frozen_string_literal: true

require 'monitor'

module H2
  module MVStore
    class StreamIdentifier
      include Enumerable
      Part = Data.define(:kind, :length, :payload)

      def initialize(bytes)
        raise ArgumentError, "Expected stream identifier bytes" unless bytes.is_a?(String)

        @bytes = bytes.b.freeze
      end

      def self.encode(kind, length, payload)
        buffer = Buffer.new.put_byte(kind)
        kind == 2 ? DataUtils.write_var_long(buffer,length) : DataUtils.write_var_int(buffer,length)
        kind.zero? ? buffer.write(payload) : DataUtils.write_var_long(buffer,payload)
        buffer.data
      end

      def each
        return enum_for(__method__) unless block_given?

        buffer = Buffer.new(@bytes)
        until buffer.remaining.zero?
          kind = buffer.byte
          raise Error.new(6, "Invalid stream identifier tag") unless (0..2).cover?(kind)

          length = kind == 2 ? DataUtils.read_var_long(buffer) : DataUtils.read_var_int(buffer)
          raise Error.new(6, "Negative stream fragment length") if length.negative?

          payload = kind.zero? ? buffer.read(length).freeze : DataUtils.read_var_long(buffer)
          yield Part.new(kind,length,payload)
        end
        self
      end

      def length
        total = sum(&:length) & DataUtils::UINT64
        total >= (1 << 63) ? total - (1 << 64) : total
      end

      def in_place? = all? { it.kind.zero? }
    end

    class StreamReader
      attr_reader :pos, :size
      alias tell pos
      alias length size

      def initialize(store, id)
        @store = store
        identifier = StreamIdentifier.new(id)
        @size = identifier.length
        raise Error.new(6, "Stream length overflow") if size.negative?

        @frames = [[identifier.each,nil]]
        @active = {}
        @pos = @skip = @offset = 0
        @buffer = nil
        @closed = false
      end

      def read(length = nil, output = nil)
        length = Integer.try_convert(length) || raise(TypeError, "Expected read length") unless length.nil?
        raise ArgumentError, "Negative read length" if length && length.negative?

        result = +''.b
        while length.nil? || result.bytesize < length
          begin
            result << readpartial(length ? length - result.bytesize : @store.max_block_size)
          rescue EOFError
            break
          end
        end
        if length && length.positive? && result.empty?
          output&.clear
          return nil
        end

        output ? output.replace(result) : result
      end

      def readpartial(length, output = nil)
        length = Integer.try_convert(length) || raise(TypeError, "Expected read length")
        raise ArgumentError, "Negative read length" if length.negative?
        return output ? output.clear : ''.b if length.zero?

        until @buffer && @offset < @buffer.bytesize
          @buffer = next_buffer
          @offset = 0
          unless @buffer
            output&.clear
            raise EOFError, "End of stored stream"
          end
        end
        count = [length,@buffer.bytesize - @offset].min
        result = @buffer.byteslice(@offset,count)
        @offset += count
        @pos += count
        output ? output.replace(result) : result
      rescue Error => error
        raise unless error.code == 50

        raise IOError.new("Stored stream block is missing"), cause: error
      end

      def getbyte = read(1)&.getbyte(0)
      def eof? = pos >= size
      def closed? = @closed

      def skip(count)
        count = Integer.try_convert(count) || raise(TypeError, "Expected skip length")
        raise ArgumentError, "Negative skip length" if count.negative?

        count = [count,size - pos].min
        return 0 if count.zero?

        if @buffer && @offset < @buffer.bytesize
          count = [count,@buffer.bytesize - @offset].min
          @offset += count
        else
          @buffer = nil
          @skip += count
        end
        @pos += count
        count
      end

      def close
        @buffer = nil
        @frames.clear
        @active.clear
        @pos = size
        @closed = true
        nil
      end

      private

      def next_buffer
        until @frames.empty?
          begin
            part = @frames.last.first.next
          rescue StopIteration
            @active.delete(@frames.pop.last)
            next
          end
          if @skip >= part.length
            @skip -= part.length
            next
          end
          if part.kind == 2
            raise Error.new(6, "Cyclic indirect stream identifier") if @active[part.payload]

            @active[part.payload] = true
            @frames << [StreamIdentifier.new(@store.block(part.payload)).each,part.payload]
          else
            bytes = part.kind.zero? ? part.payload : @store.block(part.payload)
            raise Error.new(6, "Stored stream block length differs") unless bytes.bytesize == part.length

            bytes = bytes.byteslice(@skip,bytes.bytesize - @skip)
            @skip = 0
            return bytes
          end
        end
        nil
      end
    end

    class StreamStore
      attr_reader :map, :min_block_size, :max_block_size

      def initialize(map, min_block_size: 256, max_block_size: 256 * 1024, on_store: nil)
        unless min_block_size.is_a?(Integer) && (0...(1 << 31)).cover?(min_block_size) &&
            max_block_size.is_a?(Integer) && (1...(1 << 31)).cover?(max_block_size)
          raise ArgumentError, "Invalid stream block sizes"
        end
        @map, @min_block_size, @max_block_size, @on_store = map, min_block_size, max_block_size, on_store
        @next_key = 0
        @monitor = Monitor.new
      end

      def next_key = @monitor.synchronize { @next_key }
      def next_key=(key)
        @monitor.synchronize { @next_key = Codecs::LONG.copy(key) }
      end

      def put(input)
        @monitor.synchronize do
          id = +''.b
          owned = []
          level = 0
          begin
            until put_level(id,input,level,owned)
              if id.bytesize > max_block_size / 2
                id = indirect(id,owned)
                level += 1
              end
            end
            id = indirect(id,owned) if id.bytesize > min_block_size * 2
            id.freeze
          rescue IOError, RangeError
            owned.reverse_each { map.delete(it) }
            raise
          end
        end
      end

      def get(id) = StreamReader.new(self,id)
      def length(id) = StreamIdentifier.new(id).length
      def in_place?(id) = StreamIdentifier.new(id).in_place?

      def block(key)
        map[key] || raise(Error.new(50, "Stream block #{key} not found"))
      end

      def max_block_key(id)
        each_block_key(id).max || -1
      end

      def remove(id)
        each_block_key(id) { map.delete(it) }
        nil
      end

      def self.describe(id)
        identifier = StreamIdentifier.new(id)
        parts = identifier.map do |part|
          case part.kind
          when 0 then "data len=#{part.length}"
          when 1 then "block #{part.payload} len=#{part.length}"
          when 2 then "indirect block #{part.payload} len=#{part.length}"
          end
        end
        (parts + ["length=#{identifier.length}"]).join(', ')
      end

      private

      def each_block_key(id, active = {}, &visit)
        return enum_for(__method__,id) unless visit

        StreamIdentifier.new(id).each do |part|
          next if part.kind.zero?

          if part.kind == 2
            raise Error.new(6, "Cyclic indirect stream identifier") if active[part.payload]

            active[part.payload] = true
            each_block_key(block(part.payload),active,&visit)
            active.delete(part.payload)
          end
          visit.call(part.payload)
        end
      end

      def put_level(id, input, level, owned)
        if level.positive?
          nested = +''.b
          loop do
            eof = put_level(nested,input,level - 1,owned)
            if nested.bytesize > max_block_size / 2
              id << indirect(nested,owned)
              return eof
            elsif eof
              id << nested
              return true
            end
          end
        end
        bytes = read_block(input)
        return true if bytes.empty?

        id << if bytes.bytesize < min_block_size
          StreamIdentifier.encode(0,bytes.bytesize,bytes)
        else
          StreamIdentifier.encode(1,bytes.bytesize,write_block(bytes,owned))
        end
        bytes.bytesize < max_block_size
      end

      def read_block(input)
        bytes = +''.b
        while bytes.bytesize < max_block_size
          begin
            data = input.read(max_block_size - bytes.bytesize)
          rescue IOError
            raise
          rescue StandardError => error
            raise IOError.new(error.message), cause: error
          end
          break if data.nil? || data == ''
          unless data.is_a?(String) && data.bytesize <= max_block_size - bytes.bytesize
            raise IOError, "Input returned an invalid stream block"
          end
          bytes << data.b
        end
        bytes
      end

      def indirect(id, owned)
        StreamIdentifier.encode(2,length(id),write_block(id,owned))
      end

      def write_block(bytes, owned)
        key = @next_key
        @next_key = increment(key)
        if map.key?(key)
          low, high = key, (1 << 63) - 1
          while low < high
            middle = low + (high - low) / 2
            map.key?(middle) ? low = middle + 1 : high = middle
          end
          key = low
          @next_key = increment(key)
          raise RangeError, "Stream block key range is exhausted" if key == (1 << 63) - 1 && map.key?(key)
        end
        map[key] = bytes.b.freeze
        owned << key
        @on_store&.call(bytes.bytesize)
        key
      end

      def increment(key)
        key == (1 << 63) - 1 ? -(1 << 63) : key + 1
      end
    end
  end
end

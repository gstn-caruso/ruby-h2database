# frozen_string_literal: true

module H2
  module MVStore
    class LimitedInput
      def initialize(input, remaining)
        @input, @remaining = input, remaining
      end

      def read(length)
        return ''.b if length.zero?
        return nil if @remaining.zero?

        value = @input.read([length,@remaining].min)
        @remaining -= value.bytesize if value
        value
      end
    end

    class Utf16Input
      def initialize(input)
        @input = input
        @encoding = input.respond_to?(:external_encoding) && input.external_encoding
        @encoding = Encoding::UTF_8 if !@encoding || @encoding == Encoding::BINARY
        @converter = Encoding::Converter.new(@encoding,Encoding::UTF_16BE) unless [Encoding::UTF_16BE,Encoding::UTF_16LE].include?(@encoding)
        @units, @raw = +''.b, +''.b
        @eof = false
      end

      def read_units(count)
        while @units.bytesize < count * 2 && !@eof
          needed = [count - @units.bytesize / 2,4096].min
          chunk = @input.read(@converter ? needed : needed * 2)
          if chunk.nil? || chunk.empty?
            @eof = true
            raise IOError, "Incomplete UTF-16 character" unless @raw.empty?

            @units << @converter.finish.b if @converter
          elsif @converter
            @units << @converter.convert(chunk).b
          else
            @raw << chunk.b
            length = @raw.bytesize & ~1
            complete = @raw.byteslice(0,length)
            @raw = @raw.byteslice(length,@raw.bytesize - length)
            @units << (@encoding == Encoding::UTF_16LE ? complete.unpack('v*').pack('n*') : complete)
          end
        end
        return nil if @units.empty?

        length = [count * 2,@units.bytesize].min
        result = @units.byteslice(0,length)
        @units = @units.byteslice(length,@units.bytesize - length)
        result.force_encoding(Encoding::UTF_16BE)
      rescue EncodingError => error
        raise IOError.new(error.message), cause: error
      end
    end

    class Utf8LobInput
      attr_reader :characters

      def initialize(input, max_length)
        @input = input
        @remaining = max_length
        @characters = 0
        @converter = Encoding::Converter.new(Encoding::UTF_16BE,Encoding::UTF_8,invalid: :replace,undef: :replace,replace: '?')
        @buffer = +''.b
        @eof = false
      end

      def read(length)
        return ''.b if length.zero?

        while @buffer.bytesize < length && !@eof
          units = @remaining.zero? ? nil : @input.read_units([4096,@remaining].min)
          if !units || units.empty?
            @buffer << @converter.finish.b
            @eof = true
          else
            count = units.bytesize / 2
            @characters += count
            @remaining -= count
            @buffer << @converter.convert(units).b
          end
        end
        return nil if @buffer.empty?

        count = [length,@buffer.bytesize].min
        value = @buffer.byteslice(0,count)
        @buffer = @buffer.byteslice(count,@buffer.bytesize - count)
        value
      end
    end

    class LobReader
      def initialize(owner, stream)
        @owner, @stream = owner, stream
      end

      [:read,:readpartial,:getbyte,:skip,:pos,:tell,:size,:length,:eof?].each do |name|
        define_method(name) do |*arguments|
          @stream.closed? ? @stream.public_send(name,*arguments) : @owner.with_reader(self) { @stream.public_send(name,*arguments) }
        end
      end

      def closed? = @stream.closed?

      def close
        return nil if closed?

        @owner.release_reader(self) { @stream.close }
        nil
      end
    end
  end
end

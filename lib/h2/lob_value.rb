# frozen_string_literal: true

module H2
  class BlobValue < Data.define(:bytes)
    def initialize(bytes:)
      raise Error.new(22018, 'Expected BLOB bytes') unless bytes.is_a?(String)

      super(bytes: bytes.b.freeze)
    end

    def to_s = BinaryString.text(bytes)
    def precision = bytes.bytesize
    def sql = "CAST(X'#{bytes.unpack1('H*')}' AS BINARY LARGE OBJECT(#{precision}))"
  end

  class ClobValue < Data.define(:bytes, :characters)
    def initialize(bytes:, characters: nil)
      raise Error.new(22018, 'Expected CLOB bytes') unless bytes.is_a?(String)

      actual = CharacterString.sort_key(BinaryString.text(bytes.b)).bytesize / 2
      characters = actual if characters.nil?
      raise Error.new(22018, 'Invalid CLOB character count') unless characters.is_a?(Integer) && (0...(1 << 63)).cover?(characters)
      raise Error.new(22018, 'CLOB character count does not match its bytes') unless characters == actual

      super(bytes: bytes.b.freeze, characters: characters)
    end

    def self.parse(text)
      raise Error.new(22018,'Expected CLOB text') unless text.is_a?(String)

      units = CharacterString.sort_key(text).force_encoding(Encoding::UTF_16BE)
      raise Error.new(22018,'Incomplete UTF-16 text') if units.bytesize.odd?

      bytes = units.encode(Encoding::UTF_8,invalid: :replace,undef: :replace,replace: '?')
      new(bytes,units.bytesize / 2)
    rescue EncodingError
      raise Error.new(22018,'Invalid CLOB text encoding')
    end

    def to_s = BinaryString.text(bytes)
    def precision = characters
    def sql = "CAST(#{CharacterString.sql(to_s)} AS CHARACTER LARGE OBJECT(#{precision}))"
  end

  module LobValues
    NAMES = %w[BLOB CLOB].freeze
    MAX_PRECISION = (1 << 63) - 1
    module_function

    def value?(value) = value.is_a?(BlobValue) || value.is_a?(ClobValue)

    def contains?(type)
      return contains?(type.element_type) if type.is_a?(ArrayType)
      return type.fields.any? { contains?(it) } if type.is_a?(RowType)

      NAMES.include?(type.name)
    end

    def convert(value, name, precision:, cast:, source_type:)
      result = if name == 'BLOB'
        value.is_a?(BlobValue) ? value : BlobValue.new(BinaryString.encode(value,source_type: source_type))
      elsif value.is_a?(ClobValue)
        value
      else
        text = value.is_a?(BlobValue) ? value.to_s : Type.new('VARCHAR',nil,nil).convert(value,source_type: source_type)
        ClobValue.parse(text)
      end
      return result unless precision && result.precision > precision
      raise Error.new(22001,'LOB exceeds declared precision') unless cast

      name == 'BLOB' ? BlobValue.new(result.bytes.byteslice(0,precision)) : ClobValue.parse(CharacterString.fit(result.to_s,precision,pad: false,cast: true))
    end
  end
end

# frozen_string_literal: true

module H2
  class UUIDValue < Data.define(:bytes)
    include Comparable

    def initialize(bytes:)
      raise Error.new(22018, "UUID requires 16 bytes") unless bytes.is_a?(String) && bytes.bytesize == 16

      super(bytes: bytes.b.freeze)
    end

    def self.parse(text)
      raise Error.new(22018, "UUID requires text or binary data") unless text.is_a?(String)

      digits = text.encode(Encoding::UTF_8).gsub(/[\x00-\x20-]/, "")
      raise Error.new(22018, "Invalid UUID") unless digits.match?(/\A[0-9a-fA-F]{32}\z/)

      new([digits].pack("H*"))
    rescue EncodingError, ArgumentError
      raise Error.new(22018, "Invalid UUID text encoding")
    end

    def to_s
      bytes.unpack1("H*").then { |hex| [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-") }
    end

    def <=>(other)
      bytes <=> other.bytes if other.is_a?(UUIDValue)
    end
  end
end

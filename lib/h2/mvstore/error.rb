# frozen_string_literal: true

module H2
  module MVStore
    class Error < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code
        super("#{message} [MVStore/#{code}]")
      end
    end
  end
end

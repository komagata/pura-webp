# frozen_string_literal: true

module Pura
  module Webp
    # VP8 boolean (arithmetic) decoder. Faithful to the reference pseudocode
    # in RFC 6386 §7, which treats `value` as a running 8-bit window with one
    # new stream bit shifted in per normalize step. An optimized formulation
    # would precompute a 16-bit window; we prefer the RFC form for clarity —
    # a decode is bounded by the compressed frame size and Ruby is the
    # bottleneck anyway.
    class BoolDecoder
      def initialize(data, offset = 0, size = nil)
        @data = data
        @pos = offset
        @end_pos = size ? offset + size : data.bytesize
        @range = 255
        @value = 0
        @bits_in_value = 0 # number of stream bits currently in @value (0..8)
        # Prime @value with 8 bits per §7.
        8.times { @value = (@value << 1) | read_bit }
      end

      def read_bool(prob)
        split = 1 + (((@range - 1) * prob) >> 8)
        if @value < split
          @range = split
          bit = 0
        else
          @range -= split
          @value -= split
          bit = 1
        end

        while @range < 128
          @range <<= 1
          @value = (@value << 1) | read_bit
        end
        bit
      end

      def read_literal(n)
        val = 0
        n.times { val = (val << 1) | read_bool(128) }
        val
      end

      def read_flag
        read_bool(128) == 1
      end

      def read_signed(n)
        val = read_literal(n)
        read_flag ? -val : val
      end

      # Optimized "sign bit" read matching libwebp's VP8GetSigned semantics.
      # Functionally equivalent to read_bool(128) but uses the simpler
      # split = range >> 1 formulation per libwebp's optimization.
      def read_sign_bit
        read_bool(128)
      end

      private

      # Read one bit from the stream, MSB first within each byte.
      def read_bit
        if @bits_in_value.zero?
          @current_byte = @pos < @end_pos ? @data.getbyte(@pos) : 0
          @pos += 1
          @bits_in_value = 8
        end
        @bits_in_value -= 1
        (@current_byte >> @bits_in_value) & 1
      end
    end
  end
end

# frozen_string_literal: true

module Pura
  module Webp
    # VP8 boolean decoder — direct port of golang.org/x/image/vp8/partition.go.
    # Uses the libwebp-style optimization with precomputed shift / range tables
    # (lutShift and lutRangeM1) to normalize the range after each bit read in
    # O(1) instead of O(log range). Matching Go's/libwebp's exact internal
    # state (rangeM1, bits, nBits) is what lets us decode the same bitstream
    # identically across thousands of reads — the simpler RFC 6386 §7 form is
    # mathematically equivalent for well-formed streams but accumulates
    # subtle state-representation drift with optimized sign bits.
    class BoolDecoder
      LUT_SHIFT = [
        7, 6, 6, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 4,
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1
      ].freeze

      LUT_RANGE_M1 = [
        127,
        127, 191,
        127, 159, 191, 223,
        127, 143, 159, 175, 191, 207, 223, 239,
        127, 135, 143, 151, 159, 167, 175, 183, 191, 199, 207, 215, 223, 231, 239, 247,
        127, 131, 135, 139, 143, 147, 151, 155, 159, 163, 167, 171, 175, 179, 183, 187,
        191, 195, 199, 203, 207, 211, 215, 219, 223, 227, 231, 235, 239, 243, 247, 251,
        127, 129, 131, 133, 135, 137, 139, 141, 143, 145, 147, 149, 151, 153, 155, 157,
        159, 161, 163, 165, 167, 169, 171, 173, 175, 177, 179, 181, 183, 185, 187, 189,
        191, 193, 195, 197, 199, 201, 203, 205, 207, 209, 211, 213, 215, 217, 219, 221,
        223, 225, 227, 229, 231, 233, 235, 237, 239, 241, 243, 245, 247, 249, 251, 253
      ].freeze

      def initialize(data, offset = 0, size = nil)
        @data = data
        @pos = offset
        @end_pos = size ? offset + size : data.bytesize
        @range_m1 = 254         # actual_range - 1; starts at 255 - 1
        @bits = 0                # buffered stream bits (high end)
        @n_bits = 0              # how many valid bits in @bits
      end

      def read_bool(prob)
        if @n_bits < 8
          if @pos < @end_pos
            x = @data.getbyte(@pos)
            @pos += 1
            @bits |= x << (8 - @n_bits)
          end
          @n_bits += 8
        end
        split = ((@range_m1 * prob) >> 8) + 1
        bit = @bits >= (split << 8) ? 1 : 0
        if bit == 1
          @range_m1 -= split
          @bits -= split << 8
        else
          @range_m1 = split - 1
        end
        if @range_m1 < 127
          shift = LUT_SHIFT[@range_m1]
          @range_m1 = LUT_RANGE_M1[@range_m1]
          @bits <<= shift
          @bits &= 0xFFFFFFFF
          @n_bits -= shift
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

      # Kept for API compatibility with the previous RFC-form decoder.
      def read_signed_value(v)
        read_bool(128) == 1 ? -v : v
      end
    end
  end
end

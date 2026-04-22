# frozen_string_literal: true
#
# Ruby port of golang.org/x/image/vp8/partition.go. Copyright on the
# Go original is retained; see LICENSE-GO for the upstream BSD-3-Clause
# license. Modifications for Ruby are under the gem's MIT license.
#
# Copyright 2011 The Go Authors. All rights reserved.

module Pura
  module Webp
    # VP8 arithmetic bit decoder. Direct port of golang.org/x/image/vp8/partition.go. Follows libwebp's optimized formulation with precomputed
    # shift/range lookup tables so normalization is O(1) per bit.
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

      UNIFORM_PROB = 128

      attr_reader :unexpected_eof

      def init(buf)
        @buf = buf
        @r = 0
        @range_m1 = 254
        @bits = 0
        @n_bits = 0
        @unexpected_eof = false
      end

      def initialize(buf = nil)
        init(buf) if buf
      end

      # Reads a single arithmetic-coded bit. Returns true or false (not 0/1).
      def read_bit(prob)
        if @n_bits < 8
          if @r >= @buf.bytesize
            @unexpected_eof = true
            return false
          end
          x = @buf.getbyte(@r)
          @bits |= x << (8 - @n_bits)
          @r += 1
          @n_bits += 8
        end
        split = ((@range_m1 * prob) >> 8) + 1
        bit = @bits >= (split << 8)
        if bit
          @range_m1 -= split
          @bits -= split << 8
        else
          @range_m1 = split - 1
        end
        if @range_m1 < 127
          shift = LUT_SHIFT[@range_m1]
          @range_m1 = LUT_RANGE_M1[@range_m1]
          @bits = (@bits << shift) & 0xFFFFFFFF
          @n_bits -= shift
        end
        bit
      end

      # Reads an n-bit unsigned integer, MSB first.
      def read_uint(prob, n)
        u = 0
        while n.positive?
          n -= 1
          u |= (1 << n) if read_bit(prob)
        end
        u
      end

      # Reads an n-bit signed integer: magnitude bits followed by sign bit.
      def read_int(prob, n)
        u = read_uint(prob, n)
        read_bit(prob) ? -u : u
      end

      # Reads an "optional int": 1 prob-bit flag; if set, read n-bit signed int;
      # otherwise return 0.
      def read_optional_int(prob, n)
        return 0 unless read_bit(prob)

        read_int(prob, n)
      end
    end
  end
end

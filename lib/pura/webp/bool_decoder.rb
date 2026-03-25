# frozen_string_literal: true

module Pura
  module Webp
    class BoolDecoder
      def initialize(data, offset = 0, size = nil)
        @data = data
        @pos = offset
        @end_pos = size ? offset + size : data.bytesize

        @range = 255
        @value = 0
        @bits_left = 0

        load_initial
      end

      def read_bool(prob)
        split = 1 + (((@range - 1) * prob) >> 8)
        big_split = split << @bits_left

        if @value >= big_split
          @range -= split
          @value -= big_split
          bit = 1
        else
          @range = split
          bit = 0
        end

        normalize
        bit
      end

      def read_literal(n)
        val = 0
        n.times do
          val = (val << 1) | read_bool(128)
        end
        val
      end

      def read_flag
        read_bool(128) == 1
      end

      def read_signed(n)
        val = read_literal(n)
        read_flag ? -val : val
      end

      def read_tree(tree, probs)
        idx = 0
        loop do
          idx += read_bool(probs[idx >> 1])
          val = tree[idx]
          return val if val <= 0

          idx = val
        end
      end

      private

      def load_initial
        # Load enough bytes to fill value register
        4.times do
          if @pos < @end_pos
            @value = (@value << 8) | @data.getbyte(@pos)
            @pos += 1
          else
            @value <<= 8
          end
          @bits_left += 8
        end
        @bits_left -= 8 # We work with bits_left relative to range position
      end

      def normalize
        while @range < 128
          @range <<= 1
          @bits_left -= 1

          next unless @bits_left.negative?

          @bits_left += 8
          if @pos < @end_pos
            @value = (@value << 8) | @data.getbyte(@pos)
            @pos += 1
          else
            @value <<= 8
          end
        end
      end
    end
  end
end

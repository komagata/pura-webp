# frozen_string_literal: true

module Pura
  module Webp
    class Encoder
      def self.encode(image, path, **_options)
        encoder = new(image)
        data = encoder.encode
        File.binwrite(path, data)
        data.bytesize
      end

      def initialize(image)
        @image = image
        @width = image.width
        @height = image.height
      end

      def encode
        vp8l_data = encode_vp8l
        wrap_riff(vp8l_data)
      end

      private

      def wrap_riff(vp8l_payload)
        chunk = String.new(encoding: Encoding::BINARY)
        chunk << "VP8L"
        chunk << [vp8l_payload.bytesize].pack("V")
        chunk << vp8l_payload
        chunk << "\x00" if vp8l_payload.bytesize.odd?

        riff = String.new(encoding: Encoding::BINARY)
        riff << "RIFF"
        riff << [4 + chunk.bytesize].pack("V")
        riff << "WEBP"
        riff << chunk
        riff
      end

      def encode_vp8l
        bw = BitWriter.new

        # VP8L signature
        bw.write_bits(0x2F, 8)

        # Image descriptor: width-1 (14 bits), height-1 (14 bits), alpha (1 bit), version (3 bits)
        bw.write_bits(@width - 1, 14)
        bw.write_bits(@height - 1, 14)
        bw.write_bits(0, 1)  # no alpha
        bw.write_bits(0, 3)  # version 0

        # No transforms
        bw.write_bits(0, 1)

        # Color cache: not used
        bw.write_bits(0, 1)

        # Number of huffman groups - 1 (just 1 group)
        # Actually for VP8L, if no meta-huffman, we just write 5 huffman tables directly

        # Collect pixels
        pixels = @image.pixels
        num_pixels = @width * @height

        greens = Array.new(num_pixels)
        reds = Array.new(num_pixels)
        blues = Array.new(num_pixels)

        num_pixels.times do |i|
          offset = i * 3
          reds[i] = pixels.getbyte(offset)
          greens[i] = pixels.getbyte(offset + 1)
          blues[i] = pixels.getbyte(offset + 2)
        end

        # Build histograms
        green_hist = Array.new(256, 0)
        red_hist = Array.new(256, 0)
        blue_hist = Array.new(256, 0)
        greens.each { |v| green_hist[v] += 1 }
        reds.each { |v| red_hist[v] += 1 }
        blues.each { |v| blue_hist[v] += 1 }

        # Build huffman code lengths for each channel
        # Green channel uses 256 + 24 = 280 symbols (literals + length codes)
        green_lengths = build_huffman_lengths(green_hist, 280)
        red_lengths = build_huffman_lengths(red_hist, 256)
        blue_lengths = build_huffman_lengths(blue_hist, 256)

        # Alpha: all 255
        alpha_lengths = Array.new(256, 0)
        alpha_lengths[255] = 1

        # Distance: not used
        dist_lengths = Array.new(40, 0)

        # Write 5 huffman tables
        write_code_lengths(bw, green_lengths)
        write_code_lengths(bw, red_lengths)
        write_code_lengths(bw, blue_lengths)
        write_code_lengths(bw, alpha_lengths)
        write_code_lengths(bw, dist_lengths)

        # Build actual codes
        green_codes = canonical_codes(green_lengths)
        red_codes = canonical_codes(red_lengths)
        blue_codes = canonical_codes(blue_lengths)
        alpha_codes = canonical_codes(alpha_lengths)

        # Encode pixels
        num_pixels.times do |i|
          emit_code(bw, green_codes, greens[i])
          emit_code(bw, red_codes, reds[i])
          emit_code(bw, blue_codes, blues[i])
          emit_code(bw, alpha_codes, 255)
        end

        bw.finish
      end

      # Build huffman code lengths from histogram
      def build_huffman_lengths(hist, max_symbols)
        non_zero = []
        hist.each_with_index { |c, s| non_zero << [c, s] if c > 0 }

        lengths = Array.new(max_symbols, 0)

        if non_zero.empty?
          return lengths
        elsif non_zero.size == 1
          lengths[non_zero[0][1]] = 1
          return lengths
        end

        # Build huffman tree
        nodes = non_zero.sort_by { |c, _| c }.map { |c, s| { count: c, sym: s } }

        while nodes.size > 1
          a = nodes.shift
          b = nodes.shift
          parent = { count: a[:count] + b[:count], sym: nil, left: a, right: b }
          idx = nodes.bsearch_index { |n| n[:count] >= parent[:count] } || nodes.size
          nodes.insert(idx, parent)
        end

        # Extract lengths
        assign_depth(nodes[0], 0, lengths)

        # Cap at 15
        lengths.map! { |l| [l, 15].min }
        lengths
      end

      def assign_depth(node, depth, lengths)
        if node[:left].nil?
          lengths[node[:sym]] = [depth, 1].max
        else
          assign_depth(node[:left], depth + 1, lengths)
          assign_depth(node[:right], depth + 1, lengths)
        end
      end

      # Build canonical huffman codes from lengths
      def canonical_codes(lengths)
        max_len = lengths.max || 0
        return {} if max_len == 0

        bl_count = Array.new(max_len + 1, 0)
        lengths.each { |l| bl_count[l] += 1 if l > 0 }

        next_code = Array.new(max_len + 1, 0)
        code = 0
        1.upto(max_len) do |bits|
          code = (code + bl_count[bits - 1]) << 1
          next_code[bits] = code
        end

        codes = {}
        lengths.each_with_index do |len, sym|
          next if len == 0

          codes[sym] = [next_code[len], len]
          next_code[len] += 1
        end
        codes
      end

      def emit_code(bw, codes, sym)
        return if codes.size <= 1  # single-symbol table: 0 bits needed

        entry = codes[sym]
        return unless entry

        code, len = entry
        # VP8L: huffman codes are stored with bits reversed (MSB of code goes to LSB of stream)
        len.times do |i|
          bw.write_bits((code >> (len - 1 - i)) & 1, 1)
        end
      end

      # Write code lengths to bitstream using the VP8L format
      def write_code_lengths(bw, lengths)
        # Find how many symbols we actually have
        non_zero_count = lengths.count { |l| l > 0 }
        non_zero_syms = []
        lengths.each_with_index { |l, s| non_zero_syms << s if l > 0 }

        if non_zero_count == 0
          # Write simple code with 1 symbol (symbol 0)
          bw.write_bits(1, 1)  # is_simple
          bw.write_bits(0, 1)  # num_symbols - 1 = 0
          bw.write_bits(0, 1)  # is_first_8bit = false (1-bit symbol)
          bw.write_bits(0, 1)  # symbol = 0
        elsif non_zero_count == 1
          sym = non_zero_syms[0]
          bw.write_bits(1, 1)   # is_simple
          bw.write_bits(0, 1)   # num_symbols - 1 = 0
          if sym < 2
            bw.write_bits(0, 1)  # 1-bit symbol
            bw.write_bits(sym, 1)
          else
            bw.write_bits(1, 1)  # 8-bit symbol
            bw.write_bits(sym, 8)
          end
        elsif non_zero_count == 2
          bw.write_bits(1, 1)   # is_simple
          bw.write_bits(1, 1)   # num_symbols - 1 = 1 (2 symbols)
          s0 = non_zero_syms[0]
          s1 = non_zero_syms[1]
          if s0 < 2
            bw.write_bits(0, 1)  # 1-bit
            bw.write_bits(s0, 1)
          else
            bw.write_bits(1, 1)  # 8-bit
            bw.write_bits(s0, 8)
          end
          bw.write_bits(s1, 8)
        else
          write_normal_code_lengths(bw, lengths)
        end
      end

      def write_normal_code_lengths(bw, lengths)
        bw.write_bits(0, 1)  # is_simple = false

        # Trim trailing zeros
        num_symbols = (lengths.rindex { |l| l > 0 } || 0) + 1

        # Code length alphabet: 0-15 literal lengths, 16=repeat, 17=zero run 3-10, 18=zero run 11-138
        # VP8L code length code order
        kCodeLengthCodeOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

        # RLE encode the code lengths
        rle = rle_encode(lengths, num_symbols)

        # Build histogram of RLE symbols
        cl_hist = Array.new(19, 0)
        rle.each { |sym, _, _| cl_hist[sym] += 1 }

        # Build code lengths for code length alphabet
        cl_lengths = build_huffman_lengths(cl_hist, 19)

        # Determine num_code_length_codes (at least 4)
        num_cl = 4
        kCodeLengthCodeOrder.each_with_index do |order_idx, i|
          num_cl = i + 1 if cl_lengths[order_idx] > 0
        end
        num_cl = [num_cl, 4].max

        bw.write_bits(num_cl - 4, 4)

        # Write code length code lengths
        num_cl.times do |i|
          bw.write_bits(cl_lengths[kCodeLengthCodeOrder[i]], 3)
        end

        # Build codes for code length symbols
        cl_codes = canonical_codes(cl_lengths)

        # Write max_symbol if needed
        # Default max_symbol depends on alphabet type, just use num_symbols
        # Signal that we use default by not writing anything extra
        # Actually VP8L always defaults, no need

        # Write the RLE-encoded code lengths
        rle.each do |sym, extra_bits, extra_val|
          emit_code(bw, cl_codes, sym)
          case sym
          when 16 then bw.write_bits(extra_val, 2)
          when 17 then bw.write_bits(extra_val, 3)
          when 18 then bw.write_bits(extra_val, 7)
          end
        end
      end

      def rle_encode(lengths, num_symbols)
        result = []
        i = 0
        while i < num_symbols
          val = lengths[i]
          if val == 0
            run = 0
            run += 1 while i + run < num_symbols && lengths[i + run] == 0
            i += run
            while run > 0
              if run >= 11
                extra = [run - 11, 127].min
                result << [18, 7, extra]
                run -= 11 + extra
              elsif run >= 3
                extra = run - 3
                result << [17, 3, extra]
                run -= 3 + extra
              else
                result << [0, 0, 0]
                run -= 1
              end
            end
          else
            result << [val, 0, 0]
            i += 1
            # Count repeats of same value
            run = 0
            run += 1 while i + run < num_symbols && lengths[i + run] == val
            while run >= 3
              extra = [run - 3, 3].min
              result << [16, 2, extra]
              run -= 3 + extra
            end
            run.times do
              result << [val, 0, 0]
            end
            i += run
          end
        end
        result
      end

      # Bit writer (LSB-first, VP8L format)
      class BitWriter
        def initialize
          @data = String.new(encoding: Encoding::BINARY)
          @current = 0
          @bits = 0
        end

        def write_bits(value, num_bits)
          num_bits.times do |i|
            @current |= ((value >> i) & 1) << @bits
            @bits += 1
            flush_byte if @bits == 8
          end
        end

        def finish
          @data << (@current & 0xFF).chr if @bits > 0
          @data
        end

        private

        def flush_byte
          @data << (@current & 0xFF).chr
          @current = 0
          @bits = 0
        end
      end
    end
  end
end

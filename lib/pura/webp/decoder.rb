# frozen_string_literal: true

module Pura
  module Webp
    class DecodeError < StandardError; end

    class Decoder
      def self.decode(input)
        data = if input.is_a?(String) && !input.include?("\0") && input.length < 4096 && File.exist?(input)
                 File.binread(input)
               else
                 input
               end
        new(data).decode
      end

      def initialize(data)
        @data = data.b
        @pos = 0
      end

      def decode
        parse_riff
      end

      private

      # ---- Phase 0: RIFF Container ----

      def parse_riff
        # RIFF header
        riff = read_bytes(4)
        raise DecodeError, "not a RIFF file" unless riff == "RIFF"

        file_size = read_u32_le
        webp = read_bytes(4)
        raise DecodeError, "not a WebP file" unless webp == "WEBP"

        # Read first chunk
        chunk_fourcc = read_bytes(4)
        chunk_size = read_u32_le

        case chunk_fourcc
        when "VP8 "
          decode_vp8_lossy(chunk_size)
        when "VP8L"
          raise DecodeError, "VP8L (lossless WebP) is not yet supported"
        when "VP8X"
          raise DecodeError, "VP8X (extended WebP) is not yet supported"
        else
          raise DecodeError, "unknown WebP chunk: #{chunk_fourcc.inspect}"
        end
      end

      # ---- Phase 1: VP8 Frame Header ----

      def decode_vp8_lossy(chunk_size)
        chunk_start = @pos

        # Frame tag (3 bytes, little-endian 24-bit)
        b0 = read_u8
        b1 = read_u8
        b2 = read_u8
        frame_tag = b0 | (b1 << 8) | (b2 << 16)

        keyframe = (frame_tag & 0x01) == 0  # 0 = keyframe
        version = (frame_tag >> 1) & 0x07
        show_frame = (frame_tag >> 4) & 0x01
        first_part_size = (frame_tag >> 5) & 0x7FFFF

        raise DecodeError, "not a keyframe" unless keyframe

        # Keyframe header: start code (3 bytes) + size info (7 bytes)
        sc0 = read_u8
        sc1 = read_u8
        sc2 = read_u8
        raise DecodeError, "invalid VP8 start code" unless sc0 == 0x9D && sc1 == 0x01 && sc2 == 0x2A

        # Width and height (16-bit LE each, with scale in upper 2 bits)
        size0 = read_u16_le
        size1 = read_u16_le

        width = size0 & 0x3FFF
        h_scale = size0 >> 14
        height = size1 & 0x3FFF
        v_scale = size1 >> 14

        # First partition starts after the 10-byte keyframe header
        first_part_offset = @pos
        first_part_data = @data.byteslice(chunk_start + 3, first_part_size)

        # Token (coefficient) data follows the first partition
        token_offset = chunk_start + 3 + first_part_size
        token_data = @data.byteslice(token_offset, chunk_size - 3 - first_part_size)

        # Phase 3: Parse frame header using boolean decoder
        bd = BoolDecoder.new(first_part_data)

        color_space = bd.read_flag   # 0=YCbCr
        clamping = bd.read_flag      # clamping type

        # Segmentation
        segmentation_enabled = bd.read_flag
        if segmentation_enabled
          update_mb_segmentation_map = bd.read_flag
          update_segment_feature_data = bd.read_flag
          if update_segment_feature_data
            bd.read_flag # segment_feature_mode (absolute/delta)
            4.times do
              if bd.read_flag
                bd.read_signed(7) # quantizer update
              end
            end
            4.times do
              if bd.read_flag
                bd.read_signed(6) # loop filter update
              end
            end
          end
          if update_mb_segmentation_map
            3.times do
              if bd.read_flag
                bd.read_literal(8) # segment prob
              end
            end
          end
        end

        # Loop filter
        filter_type = bd.read_flag     # 0=simple, 1=normal
        loop_filter_level = bd.read_literal(6)
        sharpness_level = bd.read_literal(3)
        loop_filter_adj_enable = bd.read_flag
        if loop_filter_adj_enable
          if bd.read_flag # mode_ref_lf_delta_update
            4.times { bd.read_signed(6) if bd.read_flag }  # ref_lf_deltas
            4.times { bd.read_signed(6) if bd.read_flag }  # mode_lf_deltas
          end
        end

        # Partitions
        num_log2_partitions = bd.read_literal(2)
        num_partitions = 1 << num_log2_partitions

        # Quantization
        y_ac_qi = bd.read_literal(7)
        y_dc_delta = bd.read_flag ? bd.read_signed(4) : 0
        y2_dc_delta = bd.read_flag ? bd.read_signed(4) : 0
        y2_ac_delta = bd.read_flag ? bd.read_signed(4) : 0
        uv_dc_delta = bd.read_flag ? bd.read_signed(4) : 0
        uv_ac_delta = bd.read_flag ? bd.read_signed(4) : 0

        # Build dequant factors
        @dequant = build_dequant(y_ac_qi, y_dc_delta, y2_dc_delta, y2_ac_delta, uv_dc_delta, uv_ac_delta)

        # Refresh entropy probs
        refresh_probs = bd.read_flag

        # Token probability updates
        @coeff_probs = VP8Tables.default_coeff_probs
        parse_token_prob_updates(bd)

        # Skip MB no-coeff skip flag
        mb_no_skip_coeff = bd.read_flag
        prob_skip_false = mb_no_skip_coeff ? bd.read_literal(8) : 0

        # Phase 4-5: Decode macroblocks
        mb_cols = (width + 15) / 16
        mb_rows = (height + 15) / 16

        # Allocate YUV buffers
        y_stride = mb_cols * 16
        uv_stride = mb_cols * 8
        y_buf = Array.new(mb_rows * 16 * y_stride, 128)
        u_buf = Array.new(mb_rows * 8 * uv_stride, 128)
        v_buf = Array.new(mb_rows * 8 * uv_stride, 128)

        # Token decoder for coefficient data
        tbd = BoolDecoder.new(token_data)

        mb_rows.times do |mb_row|
          mb_cols.times do |mb_col|
            # Skip flag
            skip = mb_no_skip_coeff ? (bd.read_bool(prob_skip_false) == 1) : false

            # Intra prediction mode for Y (keyframe)
            y_mode = read_kf_y_mode(bd)

            # UV mode
            uv_mode = read_kf_uv_mode(bd)

            unless skip
              # Decode coefficients and reconstruct
              decode_macroblock(tbd, mb_row, mb_col, y_mode, uv_mode,
                                y_buf, u_buf, v_buf, y_stride, uv_stride)
            end
          end
        end

        # Phase 6: YUV to RGB
        yuv_to_rgb(y_buf, u_buf, v_buf, width, height, y_stride, uv_stride)
      end

      # ---- VP8 Helpers ----

      DC_PRED = 0
      V_PRED = 1
      H_PRED = 2
      TM_PRED = 3
      B_PRED = 4

      KF_Y_MODE_PROBS = [145, 156, 163, 128].freeze
      KF_UV_MODE_PROBS = [142, 114, 183].freeze

      def read_kf_y_mode(bd)
        if bd.read_bool(KF_Y_MODE_PROBS[0]) == 0
          B_PRED
        elsif bd.read_bool(KF_Y_MODE_PROBS[1]) == 0
          DC_PRED
        elsif bd.read_bool(KF_Y_MODE_PROBS[2]) == 0
          V_PRED
        elsif bd.read_bool(KF_Y_MODE_PROBS[3]) == 0
          H_PRED
        else
          TM_PRED
        end
      end

      def read_kf_uv_mode(bd)
        if bd.read_bool(KF_UV_MODE_PROBS[0]) == 0
          DC_PRED
        elsif bd.read_bool(KF_UV_MODE_PROBS[1]) == 0
          V_PRED
        elsif bd.read_bool(KF_UV_MODE_PROBS[2]) == 0
          H_PRED
        else
          TM_PRED
        end
      end

      def build_dequant(y_ac_qi, y_dc_d, y2_dc_d, y2_ac_d, uv_dc_d, uv_ac_d)
        dc_table = VP8Tables::DC_QUANT
        ac_table = VP8Tables::AC_QUANT
        qi = y_ac_qi.clamp(0, 127)
        {
          y_dc: dc_table[[qi + y_dc_d, 0].max.clamp(0, 127)],
          y_ac: ac_table[qi],
          y2_dc: dc_table[[qi + y2_dc_d, 0].max.clamp(0, 127)] * 2,
          y2_ac: [ac_table[[qi + y2_ac_d, 0].max.clamp(0, 127)] * 155 / 100, 8].max,
          uv_dc: dc_table[[qi + uv_dc_d, 0].max.clamp(0, 127)],
          uv_ac: ac_table[[qi + uv_ac_d, 0].max.clamp(0, 127)]
        }
      end

      def parse_token_prob_updates(bd)
        4.times do |i|
          8.times do |j|
            3.times do |k|
              11.times do |l|
                if bd.read_bool(VP8Tables::COEFF_UPDATE_PROBS[i][j][k][l]) == 1
                  @coeff_probs[i][j][k][l] = bd.read_literal(8)
                end
              end
            end
          end
        end
      end

      def decode_macroblock(tbd, mb_row, mb_col, y_mode, uv_mode,
                            y_buf, u_buf, v_buf, y_stride, uv_stride)
        # Decode Y blocks (4x4 grid = 16 blocks)
        y_coeffs = Array.new(16) { decode_block_coeffs(tbd, 0) }

        # Decode U blocks (2x2 = 4 blocks)
        u_coeffs = Array.new(4) { decode_block_coeffs(tbd, 2) }

        # Decode V blocks (2x2 = 4 blocks)
        v_coeffs = Array.new(4) { decode_block_coeffs(tbd, 2) }

        # Dequantize and inverse transform
        y_pixels = y_coeffs.map { |c| dequant_and_idct(c, @dequant[:y_dc], @dequant[:y_ac]) }
        u_pixels = u_coeffs.map { |c| dequant_and_idct(c, @dequant[:uv_dc], @dequant[:uv_ac]) }
        v_pixels = v_coeffs.map { |c| dequant_and_idct(c, @dequant[:uv_dc], @dequant[:uv_ac]) }

        # Apply prediction and write to buffers
        base_y = mb_row * 16
        base_x = mb_col * 16

        # Simple DC prediction for Y (use 128 as predictor)
        4.times do |by|
          4.times do |bx|
            block = y_pixels[by * 4 + bx]
            16.times do |i|
              px = base_x + bx * 4 + (i % 4)
              py = base_y + by * 4 + (i / 4)
              y_buf[py * y_stride + px] = (128 + block[i]).clamp(0, 255)
            end
          end
        end

        # U/V
        uv_base_y = mb_row * 8
        uv_base_x = mb_col * 8
        2.times do |by|
          2.times do |bx|
            u_block = u_pixels[by * 2 + bx]
            v_block = v_pixels[by * 2 + bx]
            16.times do |i|
              px = uv_base_x + bx * 4 + (i % 4)
              py = uv_base_y + by * 4 + (i / 4)
              u_buf[py * uv_stride + px] = (128 + u_block[i]).clamp(0, 255)
              v_buf[py * uv_stride + px] = (128 + v_block[i]).clamp(0, 255)
            end
          end
        end
      end

      def decode_block_coeffs(tbd, plane)
        coeffs = Array.new(16, 0)
        i = 0
        while i < 16
          # Simplified: read token
          ctx = i == 0 ? 0 : 1
          band = i > 0 ? ([i - 1, 7].min) : 0
          probs = @coeff_probs[plane.clamp(0, 3)][band][ctx]

          # DCT_0 (zero token)?
          if tbd.read_bool(probs[0]) == 0
            # If first coeff and it's 0, check for EOB
            if i > 0
              break  # EOB
            end
            i += 1
            next
          end

          # Non-zero token
          if tbd.read_bool(probs[1]) == 0
            # DCT_1
            coeffs[i] = 1
          elsif tbd.read_bool(probs[2]) == 0
            # DCT_2
            coeffs[i] = 2
          elsif tbd.read_bool(probs[3]) == 0
            # DCT_3
            coeffs[i] = 3
          elsif tbd.read_bool(probs[4]) == 0
            # DCT_4
            coeffs[i] = 4
          else
            # Larger value — simplified
            coeffs[i] = 5 + tbd.read_literal(3)
          end

          # Sign bit
          coeffs[i] = -coeffs[i] if tbd.read_bool(128) == 1
          i += 1
        end
        coeffs
      end

      def dequant_and_idct(coeffs, dc_q, ac_q)
        # Dequantize
        dq = Array.new(16, 0)
        dq[0] = coeffs[0] * dc_q
        (1...16).each { |i| dq[i] = coeffs[i] * ac_q }

        # Simple 4x4 inverse DCT (simplified)
        idct4x4(dq)
      end

      def idct4x4(input)
        # Simplified 4x4 IDCT using direct computation
        output = Array.new(16, 0)

        # Row pass
        temp = Array.new(16, 0)
        4.times do |row|
          a = input[row * 4 + 0] + input[row * 4 + 2]
          b = input[row * 4 + 0] - input[row * 4 + 2]
          c = (input[row * 4 + 1] * 35468 >> 16) - (input[row * 4 + 3] * 85627 >> 16)
          d = (input[row * 4 + 1] * 85627 >> 16) + (input[row * 4 + 3] * 35468 >> 16)

          temp[row * 4 + 0] = a + d
          temp[row * 4 + 1] = b + c
          temp[row * 4 + 2] = b - c
          temp[row * 4 + 3] = a - d
        end

        # Column pass
        4.times do |col|
          a = temp[0 * 4 + col] + temp[2 * 4 + col]
          b = temp[0 * 4 + col] - temp[2 * 4 + col]
          c = (temp[1 * 4 + col] * 35468 >> 16) - (temp[3 * 4 + col] * 85627 >> 16)
          d = (temp[1 * 4 + col] * 85627 >> 16) + (temp[3 * 4 + col] * 35468 >> 16)

          output[0 * 4 + col] = (a + d + 4) >> 3
          output[1 * 4 + col] = (b + c + 4) >> 3
          output[2 * 4 + col] = (b - c + 4) >> 3
          output[3 * 4 + col] = (a - d + 4) >> 3
        end

        output
      end

      def yuv_to_rgb(y_buf, u_buf, v_buf, width, height, y_stride, uv_stride)
        pixels = String.new(encoding: Encoding::BINARY, capacity: width * height * 3)

        height.times do |row|
          width.times do |col|
            y = y_buf[row * y_stride + col]
            u = u_buf[(row / 2) * uv_stride + (col / 2)]
            v = v_buf[(row / 2) * uv_stride + (col / 2)]

            c = y - 16
            d = u - 128
            e = v - 128

            r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255)
            g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255)
            b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255)

            pixels << r.chr << g.chr << b.chr
          end
        end

        Image.new(width, height, pixels)
      end

      # ---- Byte reading helpers ----

      def read_u8
        raise DecodeError, "unexpected end of data" if @pos >= @data.bytesize

        val = @data.getbyte(@pos)
        @pos += 1
        val
      end

      def read_u16_le
        b0 = read_u8
        b1 = read_u8
        b0 | (b1 << 8)
      end

      def read_u32_le
        b0 = read_u8
        b1 = read_u8
        b2 = read_u8
        b3 = read_u8
        b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
      end

      def read_bytes(n)
        raise DecodeError, "unexpected end of data" if @pos + n > @data.bytesize

        result = @data.byteslice(@pos, n)
        @pos += n
        result
      end
    end
  end
end

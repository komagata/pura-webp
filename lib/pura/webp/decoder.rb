# frozen_string_literal: true

module Pura
  module Webp
    class DecodeError < StandardError; end

    # VP8 keyframe (lossy WebP) decoder.
    # Implements RFC 6386 for keyframes only:
    #   - Coefficient token tree (§13.5) with band/context/zigzag
    #   - Block-neighbor nonzero contexts (§13.3)
    #   - Y2 macroblock + Walsh-Hadamard inverse transform (§14.3)
    #   - 16x16 Y intra prediction (DC/V/H/TM)
    #   - 8x8 UV intra prediction (DC/V/H/TM)
    #   - 4x4 B_PRED sub-block intra prediction (10 modes)
    #   - BT.601 YUV -> RGB conversion
    # Not implemented:
    #   - Loop filter (RFC 6386 §15). Block-boundary quality will be slightly
    #     stepped until added; pixel-accuracy tests allow some tolerance.
    #   - Multiple token partitions, VP8L, VP8X, interframes.
    class Decoder
      # ---- Token constants (RFC 6386 §13.5) ----
      DCT_EOB_TOKEN   = 0
      ZERO_TOKEN      = 1
      ONE_TOKEN       = 2
      TWO_TOKEN       = 3
      THREE_TOKEN     = 4
      FOUR_TOKEN      = 5
      DCT_CAT1_TOKEN  = 6
      DCT_CAT2_TOKEN  = 7
      DCT_CAT3_TOKEN  = 8
      DCT_CAT4_TOKEN  = 9
      DCT_CAT5_TOKEN  = 10
      DCT_CAT6_TOKEN  = 11

      # Block type indices into coeff_probs. Matches the actual row order of
      # DEFAULT_COEFF_PROBS in vp8_tables.rb (libwebp convention; libvpx
      # swaps 1 and 3 — don't confuse with libvpx docs).
      BT_Y_AFTER_Y2 = 0
      BT_Y2         = 1
      BT_UV         = 2
      BT_Y_NO_Y2    = 3

      # Intra prediction modes
      DC_PRED = 0
      V_PRED  = 1
      H_PRED  = 2
      TM_PRED = 3
      B_PRED  = 4

      # B_PRED 4x4 sub-block modes
      B_DC_PRED = 0
      B_TM_PRED = 1
      B_VE_PRED = 2
      B_HE_PRED = 3
      B_LD_PRED = 4
      B_RD_PRED = 5
      B_VR_PRED = 6
      B_VL_PRED = 7
      B_HD_PRED = 8
      B_HU_PRED = 9

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

      # ---- RIFF container ----

      def parse_riff
        raise DecodeError, "not a RIFF file" unless read_bytes(4) == "RIFF"

        read_u32_le
        raise DecodeError, "not a WebP file" unless read_bytes(4) == "WEBP"

        chunk_fourcc = read_bytes(4)
        chunk_size = read_u32_le

        case chunk_fourcc
        when "VP8 " then decode_vp8_lossy(chunk_size)
        when "VP8L" then raise DecodeError, "VP8L (lossless WebP) is not yet supported"
        when "VP8X" then raise DecodeError, "VP8X (extended WebP) is not yet supported"
        else raise DecodeError, "unknown WebP chunk: #{chunk_fourcc.inspect}"
        end
      end

      # ---- VP8 frame ----

      def decode_vp8_lossy(chunk_size)
        chunk_start = @pos

        b0 = read_u8
        b1 = read_u8
        b2 = read_u8
        frame_tag = b0 | (b1 << 8) | (b2 << 16)

        keyframe = frame_tag.nobits?(0x01)
        raise DecodeError, "non-keyframe frames not supported" unless keyframe

        first_part_size = (frame_tag >> 5) & 0x7FFFF

        raise DecodeError, "invalid VP8 start code" unless read_u8 == 0x9D && read_u8 == 0x01 && read_u8 == 0x2A

        size0 = read_u16_le
        size1 = read_u16_le
        width  = size0 & 0x3FFF
        height = size1 & 0x3FFF

        first_part_data = @data.byteslice(chunk_start + 3 + 7, first_part_size)
        token_offset    = chunk_start + 3 + 7 + first_part_size
        token_data_size = chunk_size - 3 - 7 - first_part_size
        token_data      = @data.byteslice(token_offset, token_data_size)

        bd = BoolDecoder.new(first_part_data)
        parse_frame_header(bd)

        mb_cols = (width + 15) / 16
        mb_rows = (height + 15) / 16

        y_stride  = mb_cols * 16
        uv_stride = mb_cols * 8
        @y_buf = Array.new(mb_rows * 16 * y_stride, 0)
        @u_buf = Array.new(mb_rows * 8 * uv_stride, 0)
        @v_buf = Array.new(mb_rows * 8 * uv_stride, 0)

        @above_nz_y  = Array.new(mb_cols * 4, 0)
        @above_nz_u  = Array.new(mb_cols * 2, 0)
        @above_nz_v  = Array.new(mb_cols * 2, 0)
        @above_nz_y2 = Array.new(mb_cols, 0)
        @above_b_modes = Array.new(mb_cols * 4, B_DC_PRED)

        tbd = BoolDecoder.new(token_data)

        mb_rows.times do |mb_row|
          @left_nz_y  = [0, 0, 0, 0]
          @left_nz_u  = [0, 0]
          @left_nz_v  = [0, 0]
          @left_nz_y2 = 0
          @left_b_modes = Array.new(4, B_DC_PRED)

          mb_cols.times do |mb_col|
            skip = @mb_no_skip_coeff ? (bd.read_bool(@prob_skip_false) == 1) : false
            y_mode = read_kf_y_mode(bd)
            b_modes = y_mode == B_PRED ? read_b_modes(bd, mb_col) : nil
            uv_mode = read_kf_uv_mode(bd)

            residual_y = residual_u = residual_v = nil
            if skip
              reset_nonzero_for_mb(mb_col, y_mode)
            else
              residual_y, residual_u, residual_v = decode_mb_residuals(tbd, mb_col, y_mode)
            end

            apply_prediction(mb_row, mb_col, mb_cols, mb_rows, y_mode, uv_mode, b_modes,
                             residual_y, residual_u, residual_v)
            update_b_mode_context(mb_col, b_modes, y_mode)
          end
        end

        yuv_to_rgb(width, height, y_stride, uv_stride)
      end

      def reset_nonzero_for_mb(mb_col, y_mode)
        4.times do |i|
          @above_nz_y[(mb_col * 4) + i] = 0
          @left_nz_y[i] = 0
        end
        2.times do |i|
          @above_nz_u[(mb_col * 2) + i] = 0
          @left_nz_u[i] = 0
          @above_nz_v[(mb_col * 2) + i] = 0
          @left_nz_v[i] = 0
        end
        return if y_mode == B_PRED

        @above_nz_y2[mb_col] = 0
        @left_nz_y2 = 0
      end

      def update_b_mode_context(mb_col, b_modes, y_mode)
        if y_mode == B_PRED
          4.times do |i|
            @above_b_modes[(mb_col * 4) + i] = b_modes[(3 * 4) + i]
            @left_b_modes[i] = b_modes[(i * 4) + 3]
          end
        else
          # Non-B_PRED MBs expose the equivalent 4x4 context derived from the 16x16 mode.
          equiv = y_mode_to_b_equivalent(y_mode)
          4.times do |i|
            @above_b_modes[(mb_col * 4) + i] = equiv
            @left_b_modes[i] = equiv
          end
        end
      end

      def y_mode_to_b_equivalent(y_mode)
        case y_mode
        when DC_PRED then B_DC_PRED
        when V_PRED  then B_VE_PRED
        when H_PRED  then B_HE_PRED
        when TM_PRED then B_TM_PRED
        else              B_DC_PRED
        end
      end

      # ---- Frame header ----

      def parse_frame_header(bd)
        bd.read_flag # color_space (always 0)
        bd.read_flag # clamping_type

        segmentation_enabled = bd.read_flag
        if segmentation_enabled
          update_mb_seg_map = bd.read_flag
          if bd.read_flag
            bd.read_flag
            4.times { bd.read_signed(7) if bd.read_flag }
            4.times { bd.read_signed(6) if bd.read_flag }
          end
          3.times { bd.read_literal(8) if bd.read_flag } if update_mb_seg_map
        end

        bd.read_flag
        bd.read_literal(6)
        bd.read_literal(3)
        loop_filter_adj_enable = bd.read_flag
        if loop_filter_adj_enable && bd.read_flag
          4.times { bd.read_signed(6) if bd.read_flag }
          4.times { bd.read_signed(6) if bd.read_flag }
        end

        num_log2_partitions = bd.read_literal(2)
        raise DecodeError, "multiple token partitions not supported" if num_log2_partitions != 0

        y_ac_qi = bd.read_literal(7)
        y_dc_delta  = bd.read_flag ? bd.read_signed(4) : 0
        y2_dc_delta = bd.read_flag ? bd.read_signed(4) : 0
        y2_ac_delta = bd.read_flag ? bd.read_signed(4) : 0
        uv_dc_delta = bd.read_flag ? bd.read_signed(4) : 0
        uv_ac_delta = bd.read_flag ? bd.read_signed(4) : 0
        @dequant = build_dequant(y_ac_qi, y_dc_delta, y2_dc_delta, y2_ac_delta, uv_dc_delta, uv_ac_delta)

        bd.read_flag # refresh_entropy_probs

        @coeff_probs = VP8Tables.default_coeff_probs
        parse_token_prob_updates(bd)

        @mb_no_skip_coeff = bd.read_flag
        @prob_skip_false  = @mb_no_skip_coeff ? bd.read_literal(8) : 0
      end

      def build_dequant(y_ac_qi, y_dc_d, y2_dc_d, y2_ac_d, uv_dc_d, uv_ac_d)
        dc = VP8Tables::DC_QUANT
        ac = VP8Tables::AC_QUANT
        qi = y_ac_qi.clamp(0, 127)
        {
          y_dc:  dc[(qi + y_dc_d).clamp(0, 127)],
          y_ac:  ac[qi],
          y2_dc: dc[(qi + y2_dc_d).clamp(0, 127)] * 2,
          y2_ac: [ac[(qi + y2_ac_d).clamp(0, 127)] * 155 / 100, 8].max,
          uv_dc: dc[(qi + uv_dc_d).clamp(0, 127)],
          uv_ac: ac[(qi + uv_ac_d).clamp(0, 127)]
        }
      end

      def parse_token_prob_updates(bd)
        4.times do |i|
          8.times do |j|
            3.times do |k|
              11.times do |l|
                @coeff_probs[i][j][k][l] = bd.read_literal(8) if bd.read_bool(VP8Tables::COEFF_UPDATE_PROBS[i][j][k][l]) == 1
              end
            end
          end
        end
      end

      # ---- Prediction mode decoding (keyframe) ----

      def read_kf_y_mode(bd)
        # Keyframe Y-mode tree (RFC 6386 §16.1). The tree is NOT linear:
        # after ruling out B_PRED, prob[1] selects between the (DC, V) and
        # (H, TM) subtrees.
        return B_PRED if bd.read_bool(VP8Tables::KF_YMODE_PROB[0]).zero?

        if bd.read_bool(VP8Tables::KF_YMODE_PROB[1]).zero?
          bd.read_bool(VP8Tables::KF_YMODE_PROB[2]).zero? ? DC_PRED : V_PRED
        else
          bd.read_bool(VP8Tables::KF_YMODE_PROB[3]).zero? ? H_PRED : TM_PRED
        end
      end

      def read_kf_uv_mode(bd)
        return DC_PRED if bd.read_bool(VP8Tables::KF_UV_MODE_PROB[0]).zero?
        return V_PRED  if bd.read_bool(VP8Tables::KF_UV_MODE_PROB[1]).zero?
        return H_PRED  if bd.read_bool(VP8Tables::KF_UV_MODE_PROB[2]).zero?

        TM_PRED
      end

      def read_b_modes(bd, mb_col)
        modes = Array.new(16)
        16.times do |i|
          sb_row = i / 4
          sb_col = i % 4
          above = sb_row.zero? ? @above_b_modes[(mb_col * 4) + sb_col] : modes[((sb_row - 1) * 4) + sb_col]
          left  = sb_col.zero? ? @left_b_modes[sb_row] : modes[(sb_row * 4) + sb_col - 1]
          probs = VP8Tables::KF_BMODE_PROB[above][left]
          modes[i] = read_bmode_tree(bd, probs)
        end
        modes
      end

      def read_bmode_tree(bd, probs)
        idx = 0
        loop do
          bit = bd.read_bool(probs[idx >> 1])
          node = VP8Tables::BMODE_TREE[idx + bit]
          return -node if node <= 0

          idx = node
        end
      end

      # ---- Residual decoding ----

      def decode_mb_residuals(tbd, mb_col, y_mode)
        y_blocks = Array.new(16) { Array.new(16, 0) }

        if y_mode != B_PRED
          ctx = @above_nz_y2[mb_col] + @left_nz_y2
          y2_coeffs, y2_nz = decode_block(tbd, BT_Y2, 0, ctx)
          @above_nz_y2[mb_col] = y2_nz ? 1 : 0
          @left_nz_y2 = y2_nz ? 1 : 0

          dq2 = Array.new(16) { |i| i.zero? ? y2_coeffs[0] * @dequant[:y2_dc] : y2_coeffs[i] * @dequant[:y2_ac] }
          y2_dc = inverse_wht(dq2)

          16.times do |i|
            row = i / 4
            col = i % 4
            ctx = @above_nz_y[(mb_col * 4) + col] + @left_nz_y[row]
            coeffs, nz = decode_block(tbd, BT_Y_AFTER_Y2, 1, ctx)
            @above_nz_y[(mb_col * 4) + col] = nz ? 1 : 0
            @left_nz_y[row] = nz ? 1 : 0
            coeffs[0] = y2_dc[i]
            y_blocks[i] = dequant_and_idct_ac(coeffs)
          end
        else
          @above_nz_y2[mb_col] = 0
          @left_nz_y2 = 0
          16.times do |i|
            row = i / 4
            col = i % 4
            ctx = @above_nz_y[(mb_col * 4) + col] + @left_nz_y[row]
            coeffs, nz = decode_block(tbd, BT_Y_NO_Y2, 0, ctx)
            @above_nz_y[(mb_col * 4) + col] = nz ? 1 : 0
            @left_nz_y[row] = nz ? 1 : 0
            y_blocks[i] = dequant_and_idct_full(coeffs, @dequant[:y_dc], @dequant[:y_ac])
          end
        end

        # UV block order in the bitstream: all four U sub-blocks first (row-major),
        # then all four V sub-blocks. NOT interleaved. See libwebp ParseResiduals().
        u_blocks = Array.new(4) { Array.new(16, 0) }
        v_blocks = Array.new(4) { Array.new(16, 0) }
        4.times do |i|
          row = i / 2
          col = i % 2
          ctx_u = @above_nz_u[(mb_col * 2) + col] + @left_nz_u[row]
          u_coeffs, u_nz = decode_block(tbd, BT_UV, 0, ctx_u)
          @above_nz_u[(mb_col * 2) + col] = u_nz ? 1 : 0
          @left_nz_u[row] = u_nz ? 1 : 0
          u_blocks[i] = dequant_and_idct_full(u_coeffs, @dequant[:uv_dc], @dequant[:uv_ac])
        end
        4.times do |i|
          row = i / 2
          col = i % 2
          ctx_v = @above_nz_v[(mb_col * 2) + col] + @left_nz_v[row]
          v_coeffs, v_nz = decode_block(tbd, BT_UV, 0, ctx_v)
          @above_nz_v[(mb_col * 2) + col] = v_nz ? 1 : 0
          @left_nz_v[row] = v_nz ? 1 : 0
          v_blocks[i] = dequant_and_idct_full(v_coeffs, @dequant[:uv_dc], @dequant[:uv_ac])
        end

        [y_blocks, u_blocks, v_blocks]
      end

      # Walks the VP8 coefficient token tree for one 4x4 block.
      # `start_coeff` is 1 for Y-after-Y2 (skip DC position) else 0.
      # Returns [coeffs in natural order, any_nonzero].
      def decode_block(bd, block_type, start_coeff, ctx)
        coeffs = Array.new(16, 0)
        pos = start_coeff
        skip_eob = false
        prev_ctx = ctx
        any_nz = false

        while pos < 16
          band = VP8Tables::BANDS[pos]
          probs = @coeff_probs[block_type][band][prev_ctx]

          unless skip_eob
            break if bd.read_bool(probs[0]).zero?
          end

          if bd.read_bool(probs[1]).zero?
            skip_eob = true
            prev_ctx = 0
            pos += 1
            next
          end

          value = read_nonzero_token(bd, probs)
          value = -value if bd.read_bool(128) == 1
          coeffs[VP8Tables::ZIGZAG[pos]] = value
          any_nz = true
          prev_ctx = value.abs == 1 ? 1 : 2
          skip_eob = false
          pos += 1
        end

        [coeffs, any_nz]
      end

      # Already read probs[0] (EOB) and probs[1] (ZERO). Returns positive magnitude.
      def read_nonzero_token(bd, probs)
        return 1 if bd.read_bool(probs[2]).zero?

        if bd.read_bool(probs[3]).zero?
          return 2 if bd.read_bool(probs[4]).zero?

          return bd.read_bool(probs[5]).zero? ? 3 : 4
        end

        if bd.read_bool(probs[6]).zero?
          read_category(bd, bd.read_bool(probs[7]).zero? ? 0 : 1)
        elsif bd.read_bool(probs[8]).zero?
          read_category(bd, bd.read_bool(probs[9]).zero? ? 2 : 3)
        else
          read_category(bd, bd.read_bool(probs[10]).zero? ? 4 : 5)
        end
      end

      def read_category(bd, cat_idx)
        base = VP8Tables::CAT_BASE[cat_idx]
        value = 0
        VP8Tables::CAT_PROBS[cat_idx].each { |p| value = (value << 1) | bd.read_bool(p) }
        base + value
      end

      # ---- Transforms ----

      def dequant_and_idct_full(coeffs, dc_q, ac_q)
        dq = Array.new(16)
        dq[0] = coeffs[0] * dc_q
        (1...16).each { |i| dq[i] = coeffs[i] * ac_q }
        idct4x4(dq)
      end

      def dequant_and_idct_ac(coeffs)
        # coeffs[0] is already a dequantized DC (from Y2). Others need y_ac.
        dq = Array.new(16)
        dq[0] = coeffs[0]
        (1...16).each { |i| dq[i] = coeffs[i] * @dequant[:y_ac] }
        idct4x4(dq)
      end

      # 4x4 IDCT per VP8 §14.4.
      def idct4x4(input)
        tmp = Array.new(16, 0)
        4.times do |i|
          a1 = input[i] + input[8 + i]
          b1 = input[i] - input[8 + i]
          t1 = (input[4 + i] * 35_468) >> 16
          t2 = input[12 + i] + ((input[12 + i] * 20_091) >> 16)
          c1 = t1 - t2
          t1 = input[4 + i] + ((input[4 + i] * 20_091) >> 16)
          t2 = (input[12 + i] * 35_468) >> 16
          d1 = t1 + t2
          tmp[i]      = a1 + d1
          tmp[4 + i]  = b1 + c1
          tmp[8 + i]  = b1 - c1
          tmp[12 + i] = a1 - d1
        end

        output = Array.new(16, 0)
        4.times do |i|
          row = i * 4
          a1 = tmp[row] + tmp[row + 2]
          b1 = tmp[row] - tmp[row + 2]
          t1 = (tmp[row + 1] * 35_468) >> 16
          t2 = tmp[row + 3] + ((tmp[row + 3] * 20_091) >> 16)
          c1 = t1 - t2
          t1 = tmp[row + 1] + ((tmp[row + 1] * 20_091) >> 16)
          t2 = (tmp[row + 3] * 35_468) >> 16
          d1 = t1 + t2
          output[row]     = (a1 + d1 + 4) >> 3
          output[row + 1] = (b1 + c1 + 4) >> 3
          output[row + 2] = (b1 - c1 + 4) >> 3
          output[row + 3] = (a1 - d1 + 4) >> 3
        end
        output
      end

      # Inverse Walsh-Hadamard (§14.3) for Y2.
      def inverse_wht(input)
        tmp = Array.new(16, 0)
        4.times do |i|
          a1 = input[i]      + input[12 + i]
          b1 = input[4 + i]  + input[8 + i]
          c1 = input[4 + i]  - input[8 + i]
          d1 = input[i]      - input[12 + i]
          tmp[i]      = a1 + b1
          tmp[4 + i]  = c1 + d1
          tmp[8 + i]  = a1 - b1
          tmp[12 + i] = d1 - c1
        end

        out = Array.new(16, 0)
        4.times do |i|
          row = i * 4
          a1 = tmp[row]     + tmp[row + 3]
          b1 = tmp[row + 1] + tmp[row + 2]
          c1 = tmp[row + 1] - tmp[row + 2]
          d1 = tmp[row]     - tmp[row + 3]
          out[row]     = (a1 + b1 + 3) >> 3
          out[row + 1] = (c1 + d1 + 3) >> 3
          out[row + 2] = (a1 - b1 + 3) >> 3
          out[row + 3] = (d1 - c1 + 3) >> 3
        end
        out
      end

      # ---- Prediction + reconstruction ----

      def apply_prediction(mb_row, mb_col, mb_cols, mb_rows, y_mode, uv_mode, b_modes,
                           residual_y, residual_u, residual_v)
        y_stride  = mb_cols * 16
        uv_stride = mb_cols * 8
        base_y = mb_row * 16
        base_x = mb_col * 16
        uv_by  = mb_row * 8
        uv_bx  = mb_col * 8

        if y_mode == B_PRED
          predict_b_pred_y(base_x, base_y, y_stride, mb_row, mb_col, mb_cols, mb_rows, b_modes, residual_y)
        else
          predict_intra16(@y_buf, base_x, base_y, y_stride, mb_row, mb_col, y_mode)
          apply_y_residual_16x16(base_x, base_y, y_stride, residual_y) if residual_y
        end

        predict_intra8(@u_buf, uv_bx, uv_by, uv_stride, mb_row, mb_col, uv_mode)
        apply_uv_residual(@u_buf, uv_bx, uv_by, uv_stride, residual_u) if residual_u

        predict_intra8(@v_buf, uv_bx, uv_by, uv_stride, mb_row, mb_col, uv_mode)
        apply_uv_residual(@v_buf, uv_bx, uv_by, uv_stride, residual_v) if residual_v
      end

      def predict_intra16(buf, base_x, base_y, stride, mb_row, mb_col, mode)
        above_avail = mb_row.positive?
        left_avail  = mb_col.positive?

        above = Array.new(16, 127)
        left  = Array.new(16, 129)

        if above_avail
          16.times { |i| above[i] = buf[((base_y - 1) * stride) + base_x + i] }
        end
        if left_avail
          16.times { |i| left[i] = buf[((base_y + i) * stride) + base_x - 1] }
        end

        case mode
        when DC_PRED
          dc = compute_dc_pred(above, left, above_avail, left_avail, 16)
          16.times { |y| 16.times { |x| buf[((base_y + y) * stride) + base_x + x] = dc } }
        when V_PRED
          16.times { |y| 16.times { |x| buf[((base_y + y) * stride) + base_x + x] = above[x] } }
        when H_PRED
          16.times { |y| 16.times { |x| buf[((base_y + y) * stride) + base_x + x] = left[y] } }
        when TM_PRED
          tl = compute_top_left(buf, base_x, base_y, stride, above_avail, left_avail)
          16.times do |y|
            16.times do |x|
              buf[((base_y + y) * stride) + base_x + x] = (left[y] + above[x] - tl).clamp(0, 255)
            end
          end
        else
          raise DecodeError, "bad 16x16 Y mode: #{mode}"
        end
      end

      def predict_intra8(buf, base_x, base_y, stride, mb_row, mb_col, mode)
        above_avail = mb_row.positive?
        left_avail  = mb_col.positive?

        above = Array.new(8, 127)
        left  = Array.new(8, 129)

        if above_avail
          8.times { |i| above[i] = buf[((base_y - 1) * stride) + base_x + i] }
        end
        if left_avail
          8.times { |i| left[i] = buf[((base_y + i) * stride) + base_x - 1] }
        end

        case mode
        when DC_PRED
          dc = compute_dc_pred(above, left, above_avail, left_avail, 8)
          8.times { |y| 8.times { |x| buf[((base_y + y) * stride) + base_x + x] = dc } }
        when V_PRED
          8.times { |y| 8.times { |x| buf[((base_y + y) * stride) + base_x + x] = above[x] } }
        when H_PRED
          8.times { |y| 8.times { |x| buf[((base_y + y) * stride) + base_x + x] = left[y] } }
        when TM_PRED
          tl = compute_top_left(buf, base_x, base_y, stride, above_avail, left_avail)
          8.times do |y|
            8.times do |x|
              buf[((base_y + y) * stride) + base_x + x] = (left[y] + above[x] - tl).clamp(0, 255)
            end
          end
        else
          raise DecodeError, "bad UV mode: #{mode}"
        end
      end

      def compute_dc_pred(above, left, above_avail, left_avail, size)
        if above_avail && left_avail
          (above.sum + left.sum + size) >> (Math.log2(size * 2).to_i)
        elsif above_avail
          (above.sum + (size / 2)) >> Math.log2(size).to_i
        elsif left_avail
          (left.sum + (size / 2)) >> Math.log2(size).to_i
        else
          128
        end
      end

      def compute_top_left(buf, base_x, base_y, stride, above_avail, left_avail)
        return 127 unless above_avail
        return 129 unless left_avail

        buf[((base_y - 1) * stride) + base_x - 1]
      end

      def apply_y_residual_16x16(base_x, base_y, stride, blocks)
        16.times do |i|
          sb_row = i / 4
          sb_col = i % 4
          by = base_y + (sb_row * 4)
          bx = base_x + (sb_col * 4)
          block = blocks[i]
          4.times do |y|
            4.times do |x|
              off = ((by + y) * stride) + bx + x
              @y_buf[off] = (@y_buf[off] + block[(y * 4) + x]).clamp(0, 255)
            end
          end
        end
      end

      def apply_uv_residual(buf, base_x, base_y, stride, blocks)
        4.times do |i|
          sb_row = i / 2
          sb_col = i % 2
          by = base_y + (sb_row * 4)
          bx = base_x + (sb_col * 4)
          block = blocks[i]
          4.times do |y|
            4.times do |x|
              off = ((by + y) * stride) + bx + x
              buf[off] = (buf[off] + block[(y * 4) + x]).clamp(0, 255)
            end
          end
        end
      end

      # ---- B_PRED (per-sub-block 4x4 prediction) ----

      def predict_b_pred_y(base_x, base_y, stride, mb_row, mb_col, mb_cols, mb_rows, b_modes, residual_y)
        16.times do |i|
          sb_row = i / 4
          sb_col = i % 4
          sx = base_x + (sb_col * 4)
          sy = base_y + (sb_row * 4)
          predict_b4x4(@y_buf, sx, sy, stride, mb_row, mb_col, mb_cols, mb_rows, sb_row, sb_col, b_modes[i])
          next unless residual_y

          block = residual_y[i]
          4.times do |dy|
            4.times do |dx|
              off = ((sy + dy) * stride) + sx + dx
              @y_buf[off] = (@y_buf[off] + block[(dy * 4) + dx]).clamp(0, 255)
            end
          end
        end
      end

      def predict_b4x4(buf, x, y, stride, mb_row, mb_col, mb_cols, _mb_rows, sb_row, sb_col, mode)
        above_exists = mb_row.positive? || sb_row.positive?
        left_exists  = mb_col.positive? || sb_col.positive?

        t = Array.new(8, 127)
        if above_exists
          8.times { |i| t[i] = buf[((y - 1) * stride) + x + i] }
          ar_avail = sub_block_above_right_available(mb_row, mb_col, mb_cols, sb_row, sb_col)
          4.times { |i| t[4 + i] = t[3] } unless ar_avail
        end

        l = Array.new(4, 129)
        if left_exists
          4.times { |i| l[i] = buf[((y + i) * stride) + x - 1] }
        end

        tl = if above_exists && left_exists
               buf[((y - 1) * stride) + x - 1]
             elsif above_exists
               129
             else
               127
             end

        case mode
        when B_DC_PRED
          avg = (t[0] + t[1] + t[2] + t[3] + l[0] + l[1] + l[2] + l[3] + 4) >> 3
          4.times { |yi| 4.times { |xi| buf[((y + yi) * stride) + x + xi] = avg } }
        when B_TM_PRED
          4.times do |yi|
            4.times do |xi|
              buf[((y + yi) * stride) + x + xi] = (l[yi] + t[xi] - tl).clamp(0, 255)
            end
          end
        when B_VE_PRED
          avg = [
            ((tl + (2 * t[0]) + t[1] + 2) >> 2),
            ((t[0] + (2 * t[1]) + t[2] + 2) >> 2),
            ((t[1] + (2 * t[2]) + t[3] + 2) >> 2),
            ((t[2] + (2 * t[3]) + t[4] + 2) >> 2)
          ]
          4.times { |yi| 4.times { |xi| buf[((y + yi) * stride) + x + xi] = avg[xi] } }
        when B_HE_PRED
          avg = [
            ((tl + (2 * l[0]) + l[1] + 2) >> 2),
            ((l[0] + (2 * l[1]) + l[2] + 2) >> 2),
            ((l[1] + (2 * l[2]) + l[3] + 2) >> 2),
            ((l[2] + (3 * l[3]) + 2) >> 2)
          ]
          4.times { |yi| 4.times { |xi| buf[((y + yi) * stride) + x + xi] = avg[yi] } }
        when B_LD_PRED
          predict_b_ld(buf, x, y, stride, t)
        when B_RD_PRED
          predict_b_rd(buf, x, y, stride, t, l, tl)
        when B_VR_PRED
          predict_b_vr(buf, x, y, stride, t, l, tl)
        when B_VL_PRED
          predict_b_vl(buf, x, y, stride, t)
        when B_HD_PRED
          predict_b_hd(buf, x, y, stride, t, l, tl)
        when B_HU_PRED
          predict_b_hu(buf, x, y, stride, l)
        else
          raise DecodeError, "bad b_mode: #{mode}"
        end
      end

      def predict_b_ld(buf, x, y, stride, t)
        # p[i] = (t[i] + 2*t[i+1] + t[i+2] + 2) >> 2, for i in 0..6, with p[6] using t[6],t[7],t[7]
        p = Array.new(7)
        6.times { |i| p[i] = (t[i] + (2 * t[i + 1]) + t[i + 2] + 2) >> 2 }
        p[6] = (t[6] + (3 * t[7]) + 2) >> 2
        layout = [[0, 1, 2, 3], [1, 2, 3, 4], [2, 3, 4, 5], [3, 4, 5, 6]]
        4.times { |yi| 4.times { |xi| buf[((y + yi) * stride) + x + xi] = p[layout[yi][xi]] } }
      end

      def predict_b_rd(buf, x, y, stride, t, l, tl)
        # Diagonal "down-right". e[0..8] = l[3], l[2], l[1], l[0], tl, t[0], t[1], t[2], t[3]
        e = [l[3], l[2], l[1], l[0], tl, t[0], t[1], t[2], t[3]]
        p = Array.new(7) { |i| (e[i] + (2 * e[i + 1]) + e[i + 2] + 2) >> 2 }
        # Pixel at (row, col) uses p[3 - row + col]
        4.times do |yi|
          4.times do |xi|
            buf[((y + yi) * stride) + x + xi] = p[3 - yi + xi]
          end
        end
      end

      def predict_b_vr(buf, x, y, stride, t, l, tl)
        # Vertical-right: layout per RFC 6386 §12.3
        layout = [
          [:avg2_tl_t0,  :avg2_t0_t1,  :avg2_t1_t2,  :avg2_t2_t3],
          [:avg3_l0_tl_t0, :avg3_tl_t0_t1, :avg3_t0_t1_t2, :avg3_t1_t2_t3],
          [:avg2_l0_tl,  :avg2_tl_t0,  :avg2_t0_t1,  :avg2_t1_t2],
          [:avg3_l1_l0_tl, :avg3_l0_tl_t0, :avg3_tl_t0_t1, :avg3_t0_t1_t2]
        ]
        4.times do |yi|
          4.times do |xi|
            buf[((y + yi) * stride) + x + xi] = vr_pixel(layout[yi][xi], t, l, tl)
          end
        end
      end

      def vr_pixel(sym, t, l, tl)
        case sym
        when :avg2_tl_t0  then (tl + t[0] + 1) >> 1
        when :avg2_t0_t1  then (t[0] + t[1] + 1) >> 1
        when :avg2_t1_t2  then (t[1] + t[2] + 1) >> 1
        when :avg2_t2_t3  then (t[2] + t[3] + 1) >> 1
        when :avg2_l0_tl  then (l[0] + tl + 1) >> 1
        when :avg3_l0_tl_t0  then (l[0] + (2 * tl) + t[0] + 2) >> 2
        when :avg3_tl_t0_t1  then (tl + (2 * t[0]) + t[1] + 2) >> 2
        when :avg3_t0_t1_t2  then (t[0] + (2 * t[1]) + t[2] + 2) >> 2
        when :avg3_t1_t2_t3  then (t[1] + (2 * t[2]) + t[3] + 2) >> 2
        when :avg3_l1_l0_tl  then (l[1] + (2 * l[0]) + tl + 2) >> 2
        end
      end

      def predict_b_vl(buf, x, y, stride, t)
        layout = [
          [:avg2_t0_t1, :avg2_t1_t2, :avg2_t2_t3, :avg2_t3_t4],
          [:avg3_t0_t1_t2, :avg3_t1_t2_t3, :avg3_t2_t3_t4, :avg3_t3_t4_t5],
          [:avg2_t1_t2, :avg2_t2_t3, :avg2_t3_t4, :avg2_t4_t5],
          [:avg3_t1_t2_t3, :avg3_t2_t3_t4, :avg3_t3_t4_t5, :avg3_t4_t5_t6]
        ]
        4.times do |yi|
          4.times do |xi|
            buf[((y + yi) * stride) + x + xi] = vl_pixel(layout[yi][xi], t)
          end
        end
      end

      def vl_pixel(sym, t)
        case sym
        when :avg2_t0_t1 then (t[0] + t[1] + 1) >> 1
        when :avg2_t1_t2 then (t[1] + t[2] + 1) >> 1
        when :avg2_t2_t3 then (t[2] + t[3] + 1) >> 1
        when :avg2_t3_t4 then (t[3] + t[4] + 1) >> 1
        when :avg2_t4_t5 then (t[4] + t[5] + 1) >> 1
        when :avg3_t0_t1_t2 then (t[0] + (2 * t[1]) + t[2] + 2) >> 2
        when :avg3_t1_t2_t3 then (t[1] + (2 * t[2]) + t[3] + 2) >> 2
        when :avg3_t2_t3_t4 then (t[2] + (2 * t[3]) + t[4] + 2) >> 2
        when :avg3_t3_t4_t5 then (t[3] + (2 * t[4]) + t[5] + 2) >> 2
        when :avg3_t4_t5_t6 then (t[4] + (2 * t[5]) + t[6] + 2) >> 2
        end
      end

      def predict_b_hd(buf, x, y, stride, t, l, tl)
        layout = [
          [:avg2_l0_tl, :avg3_l1_l0_tl, :avg3_l0_tl_t0, :avg3_tl_t0_t1],
          [:avg2_l1_l0, :avg3_l2_l1_l0, :avg2_l0_tl,    :avg3_l1_l0_tl],
          [:avg2_l2_l1, :avg3_l3_l2_l1, :avg2_l1_l0,    :avg3_l2_l1_l0],
          [:avg2_l3_l2, :avg3_l3_l3_l2, :avg2_l2_l1,    :avg3_l3_l2_l1]
        ]
        4.times do |yi|
          4.times do |xi|
            buf[((y + yi) * stride) + x + xi] = hd_pixel(layout[yi][xi], t, l, tl)
          end
        end
      end

      def hd_pixel(sym, t, l, tl)
        case sym
        when :avg2_l0_tl then (l[0] + tl + 1) >> 1
        when :avg2_l1_l0 then (l[1] + l[0] + 1) >> 1
        when :avg2_l2_l1 then (l[2] + l[1] + 1) >> 1
        when :avg2_l3_l2 then (l[3] + l[2] + 1) >> 1
        when :avg3_l1_l0_tl then (l[1] + (2 * l[0]) + tl + 2) >> 2
        when :avg3_l0_tl_t0 then (l[0] + (2 * tl) + t[0] + 2) >> 2
        when :avg3_tl_t0_t1 then (tl + (2 * t[0]) + t[1] + 2) >> 2
        when :avg3_l2_l1_l0 then (l[2] + (2 * l[1]) + l[0] + 2) >> 2
        when :avg3_l3_l2_l1 then (l[3] + (2 * l[2]) + l[1] + 2) >> 2
        when :avg3_l3_l3_l2 then (l[3] + (2 * l[3]) + l[2] + 2) >> 2
        end
      end

      def predict_b_hu(buf, x, y, stride, l)
        # p0..p8 per RFC §12.3
        p0 = (l[0] + l[1] + 1) >> 1
        p1 = (l[0] + (2 * l[1]) + l[2] + 2) >> 2
        p2 = (l[1] + l[2] + 1) >> 1
        p3 = (l[1] + (2 * l[2]) + l[3] + 2) >> 2
        p4 = (l[2] + l[3] + 1) >> 1
        p5 = (l[2] + (2 * l[3]) + l[3] + 2) >> 2
        p6 = l[3]
        grid = [
          [p0, p1, p2, p3],
          [p2, p3, p4, p5],
          [p4, p5, p6, p6],
          [p6, p6, p6, p6]
        ]
        4.times do |yi|
          4.times do |xi|
            buf[((y + yi) * stride) + x + xi] = grid[yi][xi]
          end
        end
      end

      def sub_block_above_right_available(mb_row, mb_col, mb_cols, sb_row, sb_col)
        return false if sb_col == 3
        return true if sb_row.positive?
        return false if mb_row.zero?

        mb_col + 1 < mb_cols
      end

      # ---- YUV 4:2:0 -> RGB (BT.601) ----

      def yuv_to_rgb(width, height, y_stride, uv_stride)
        pixels = String.new(encoding: Encoding::BINARY, capacity: width * height * 3)
        height.times do |row|
          uv_row_base = (row / 2) * uv_stride
          y_row_base  = row * y_stride
          width.times do |col|
            y = @y_buf[y_row_base + col]
            u = @u_buf[uv_row_base + (col / 2)]
            v = @v_buf[uv_row_base + (col / 2)]
            c = y - 16
            d = u - 128
            e = v - 128
            r = (((298 * c) + (409 * e) + 128) >> 8).clamp(0, 255)
            g = (((298 * c) - (100 * d) - (208 * e) + 128) >> 8).clamp(0, 255)
            b = (((298 * c) + (516 * d) + 128) >> 8).clamp(0, 255)
            pixels << r.chr << g.chr << b.chr
          end
        end
        Image.new(width, height, pixels)
      end

      # ---- Byte readers ----

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

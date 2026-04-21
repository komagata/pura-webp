# frozen_string_literal: true

require_relative "vp8_tables"

module Pura
  module Webp
    class DecodeError < StandardError; end

    # VP8 keyframe (lossy WebP) decoder. This is a Ruby port of
    # golang.org/x/image/vp8 (BSD-3-Clause), specifically the files
    # decode.go, partition.go, pred.go, predfunc.go, idct.go, token.go,
    # quant.go and reconstruct.go. The port is as line-by-line as
    # practical, including variable names and the ybr workspace layout,
    # so bugs can be cross-checked against the upstream Go source.
    #
    # Not yet ported: filter.go (loop filter). Pixel-accuracy tests
    # allow tolerance for the small steps this introduces at block edges.
    class Decoder
      # ---- Predictor mode constants (pred.go) ----
      N_PRED = 10
      PRED_DC      = 0
      PRED_TM      = 1
      PRED_VE      = 2
      PRED_HE      = 3
      PRED_RD      = 4
      PRED_VR      = 5
      PRED_LD      = 6
      PRED_VL      = 7
      PRED_HD      = 8
      PRED_HU      = 9
      PRED_DC_TOP     = 10
      PRED_DC_LEFT    = 11
      PRED_DC_TOPLEFT = 12

      # ---- Token plane enumeration (token.go) ----
      PLANE_Y1_WITH_Y2 = 0
      PLANE_Y2         = 1
      PLANE_UV         = 2
      PLANE_Y1_SANS_Y2 = 3

      # ---- ybr workspace offsets (reconstruct.go) ----
      B_COEFF_BASE   = 256
      R_COEFF_BASE   = 256 + 64
      WHT_COEFF_BASE = 256 + 128
      YBR_Y_X = 8
      YBR_Y_Y = 1
      YBR_B_X = 8
      YBR_B_Y = 18
      YBR_R_X = 24
      YBR_R_Y = 18

      UNIFORM_PROB = 128

      # ---- Entry points ----
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
        when "VP8 " then decode_vp8_chunk(chunk_size)
        when "VP8L" then raise DecodeError, "VP8L (lossless WebP) is not yet supported"
        when "VP8X" then raise DecodeError, "VP8X (extended WebP) is not yet supported"
        else raise DecodeError, "unknown WebP chunk: #{chunk_fourcc.inspect}"
        end
      end

      # decode.go: DecodeFrameHeader + DecodeFrame + parseOtherHeaders.
      def decode_vp8_chunk(chunk_size)
        chunk_start = @pos
        chunk_end   = chunk_start + chunk_size

        # 3-byte frame tag.
        b0 = read_u8
        b1 = read_u8
        b2 = read_u8
        key_frame = (b0 & 1).zero?
        raise DecodeError, "interframes are not supported" unless key_frame

        first_partition_len = ((b0 >> 5) | (b1 << 3) | (b2 << 11)) & 0x7FFFF

        # 7-byte keyframe block.
        sc0 = read_u8
        sc1 = read_u8
        sc2 = read_u8
        raise DecodeError, "invalid VP8 start code" unless sc0 == 0x9D && sc1 == 0x01 && sc2 == 0x2A

        sz0 = read_u8
        sz1 = read_u8
        sz2 = read_u8
        sz3 = read_u8
        @width  = ((sz1 & 0x3F) << 8) | sz0
        @height = ((sz3 & 0x3F) << 8) | sz2
        @mbw = (@width  + 15) >> 4
        @mbh = (@height + 15) >> 4

        # Parse the first partition (frame header + per-MB prediction modes).
        first_partition = @data.byteslice(@pos, first_partition_len)
        @pos += first_partition_len
        @fp = BoolDecoder.new(first_partition)

        # decode.go: parseOtherHeaders body (keyframe path).
        @fp.read_bit(UNIFORM_PROB) # color space (unused)
        @fp.read_bit(UNIFORM_PROB) # clamping_type (unused)

        parse_segment_header
        parse_filter_header
        parse_other_partitions(chunk_end)
        parse_quant
        @fp.read_bit(UNIFORM_PROB) # refresh_last_frame (keyframes ignore)
        parse_token_prob
        @use_skip_prob = @fp.read_bit(UNIFORM_PROB)
        @skip_prob     = @use_skip_prob ? @fp.read_uint(UNIFORM_PROB, 8) : 0

        # decode.go: DecodeFrame reconstruction loop.
        y_stride  = @mbw * 16
        c_stride  = @mbw * 8
        @img_y  = Array.new(@mbh * 16 * y_stride, 0)
        @img_cb = Array.new(@mbh * 8 * c_stride, 0)
        @img_cr = Array.new(@mbh * 8 * c_stride, 0)
        @y_stride = y_stride
        @c_stride = c_stride

        @coeff = Array.new(400, 0)
        @ybr   = Array.new(26) { Array.new(32, 0) }
        @up_mb = Array.new(@mbw) { { pred: [0, 0, 0, 0], nz_mask: 0, nz_y16: 0 } }
        @left_mb = { pred: [0, 0, 0, 0], nz_mask: 0, nz_y16: 0 }

        @segment = 0
        @mbh.times do |mby|
          @left_mb = { pred: [0, 0, 0, 0], nz_mask: 0, nz_y16: 0 }
          @mbw.times do |mbx|
            reconstruct(mbx, mby)
          end
        end

        yuv_to_rgb_image
      end

      # ---- Segment header (decode.go: parseSegmentHeader) ----

      def parse_segment_header
        @use_segment = @fp.read_bit(UNIFORM_PROB)
        @seg_quantizer = [0, 0, 0, 0]
        @seg_filter    = [0, 0, 0, 0]
        @seg_prob      = [0xFF, 0xFF, 0xFF]
        @relative_delta = false
        unless @use_segment
          @update_map = false
          return
        end

        @update_map = @fp.read_bit(UNIFORM_PROB)
        if @fp.read_bit(UNIFORM_PROB)
          @relative_delta = !@fp.read_bit(UNIFORM_PROB)
          4.times { |i| @seg_quantizer[i] = @fp.read_optional_int(UNIFORM_PROB, 7) }
          4.times { |i| @seg_filter[i]    = @fp.read_optional_int(UNIFORM_PROB, 6) }
        end
        return unless @update_map

        3.times do |i|
          @seg_prob[i] = @fp.read_bit(UNIFORM_PROB) ? @fp.read_uint(UNIFORM_PROB, 8) : 0xFF
        end
      end

      # ---- Filter header (decode.go: parseFilterHeader) ----

      def parse_filter_header
        @filter_simple    = @fp.read_bit(UNIFORM_PROB)
        @filter_level     = @fp.read_uint(UNIFORM_PROB, 6)
        @filter_sharpness = @fp.read_uint(UNIFORM_PROB, 3)
        @filter_use_lf_delta = @fp.read_bit(UNIFORM_PROB)
        @filter_ref_lf_delta = [0, 0, 0, 0]
        @filter_mode_lf_delta = [0, 0, 0, 0]
        if @filter_use_lf_delta && @fp.read_bit(UNIFORM_PROB)
          4.times { |i| @filter_ref_lf_delta[i]  = @fp.read_optional_int(UNIFORM_PROB, 6) }
          4.times { |i| @filter_mode_lf_delta[i] = @fp.read_optional_int(UNIFORM_PROB, 6) }
        end
      end

      # ---- Other partitions (decode.go: parseOtherPartitions) ----

      def parse_other_partitions(chunk_end)
        @nop = 1 << @fp.read_uint(UNIFORM_PROB, 2)
        raise DecodeError, "multi-partition frames not supported" if @nop > 1

        # Single-partition path: the token partition is whatever remains of the chunk.
        token_data = @data.byteslice(@pos, chunk_end - @pos)
        @op = [BoolDecoder.new(token_data)]
      end

      # ---- Quantization (quant.go: parseQuant) ----

      def parse_quant
        base_q0 = @fp.read_uint(UNIFORM_PROB, 7)
        dq_y1_dc = @fp.read_optional_int(UNIFORM_PROB, 4)
        dq_y1_ac = 0
        dq_y2_dc = @fp.read_optional_int(UNIFORM_PROB, 4)
        dq_y2_ac = @fp.read_optional_int(UNIFORM_PROB, 4)
        dq_uv_dc = @fp.read_optional_int(UNIFORM_PROB, 4)
        dq_uv_ac = @fp.read_optional_int(UNIFORM_PROB, 4)
        @quant = Array.new(4) { { y1: [0, 0], y2: [0, 0], uv: [0, 0] } }
        4.times do |i|
          q = base_q0
          if @use_segment
            q = @relative_delta ? q + @seg_quantizer[i] : @seg_quantizer[i]
          end
          dc = VP8Tables::DEQUANT_DC
          ac = VP8Tables::DEQUANT_AC
          @quant[i][:y1][0] = dc[clip(q + dq_y1_dc, 0, 127)]
          @quant[i][:y1][1] = ac[clip(q + dq_y1_ac, 0, 127)]
          @quant[i][:y2][0] = dc[clip(q + dq_y2_dc, 0, 127)] * 2
          y2_ac = ac[clip(q + dq_y2_ac, 0, 127)] * 155 / 100
          @quant[i][:y2][1] = [y2_ac, 8].max
          # UV DC is clamped to 117, not 127 (see quant.go comment).
          @quant[i][:uv][0] = dc[clip(q + dq_uv_dc, 0, 117)]
          @quant[i][:uv][1] = ac[clip(q + dq_uv_ac, 0, 127)]
        end
      end

      # ---- Token probabilities (token.go: parseTokenProb) ----

      def parse_token_prob
        @token_prob = VP8Tables.default_token_prob
        4.times do |i|
          8.times do |j|
            3.times do |k|
              11.times do |l|
                @token_prob[i][j][k][l] = @fp.read_uint(UNIFORM_PROB, 8) if @fp.read_bit(VP8Tables::TOKEN_PROB_UPDATE_PROB[i][j][k][l])
              end
            end
          end
        end
      end

      # ---- Reconstruct one macroblock (reconstruct.go: reconstruct) ----

      def reconstruct(mbx, mby)
        if @update_map
          if !@fp.read_bit(@seg_prob[0])
            @segment = @fp.read_bit(@seg_prob[1]) ? 1 : 0
          else
            @segment = (@fp.read_bit(@seg_prob[2]) ? 1 : 0) + 2
          end
        end
        skip = @use_skip_prob ? @fp.read_bit(@skip_prob) : false

        @coeff.fill(0)
        prepare_ybr(mbx, mby)

        @use_pred_y16 = @fp.read_bit(145)
        if @use_pred_y16
          parse_pred_mode_y16(mbx)
        else
          parse_pred_mode_y4(mbx)
        end
        parse_pred_mode_c8

        if skip
          if @use_pred_y16
            @left_mb[:nz_y16] = 0
            @up_mb[mbx][:nz_y16] = 0
          end
          @left_mb[:nz_mask] = 0
          @up_mb[mbx][:nz_mask] = 0
          @nz_dc_mask = 0
          @nz_ac_mask = 0
        else
          parse_residuals(mbx)
        end

        reconstruct_macroblock(mbx, mby)

        # Copy ybr to the output planes.
        copy_ybr_to_image(mbx, mby)
      end

      # ---- ybr preparation (reconstruct.go: prepareYBR) ----

      def prepare_ybr(mbx, mby)
        if mbx.zero?
          (0..16).each { |y| @ybr[y][7] = 0x81 }
          (17..25).each do |y|
            @ybr[y][7]  = 0x81
            @ybr[y][23] = 0x81
          end
        else
          (0..16).each { |y| @ybr[y][7] = @ybr[y][7 + 16] }
          (17..25).each do |y|
            @ybr[y][7]  = @ybr[y][15]
            @ybr[y][23] = @ybr[y][31]
          end
        end
        if mby.zero?
          (7..27).each { |x| @ybr[0][x] = 0x7F }
          (7..15).each { |x| @ybr[17][x] = 0x7F }
          (23..31).each { |x| @ybr[17][x] = 0x7F }
        else
          16.times { |i| @ybr[0][8 + i] = @img_y[((16 * mby) - 1) * @y_stride + (16 * mbx) + i] }
          8.times  { |i| @ybr[17][8 + i]  = @img_cb[((8 * mby) - 1) * @c_stride + (8 * mbx) + i] }
          8.times  { |i| @ybr[17][24 + i] = @img_cr[((8 * mby) - 1) * @c_stride + (8 * mbx) + i] }
          if mbx == @mbw - 1
            (16..19).each { |i| @ybr[0][8 + i] = @img_y[((16 * mby) - 1) * @y_stride + (16 * mbx) + 15] }
          else
            (16..19).each { |i| @ybr[0][8 + i] = @img_y[((16 * mby) - 1) * @y_stride + (16 * mbx) + i] }
          end
        end
        [4, 8, 12].each do |y|
          @ybr[y][24] = @ybr[0][24]
          @ybr[y][25] = @ybr[0][25]
          @ybr[y][26] = @ybr[0][26]
          @ybr[y][27] = @ybr[0][27]
        end
      end

      # ---- Predictor-mode parsing (pred.go) ----

      def parse_pred_mode_y16(mbx)
        p = if !@fp.read_bit(156)
              !@fp.read_bit(163) ? PRED_DC : PRED_VE
            elsif !@fp.read_bit(128)
              PRED_HE
            else
              PRED_TM
            end
        4.times do |i|
          @up_mb[mbx][:pred][i] = p
          @left_mb[:pred][i] = p
        end
        @pred_y16 = p
      end

      def parse_pred_mode_c8
        @pred_c8 = if !@fp.read_bit(142)
                     PRED_DC
                   elsif !@fp.read_bit(114)
                     PRED_VE
                   elsif !@fp.read_bit(183)
                     PRED_HE
                   else
                     PRED_TM
                   end
      end

      def parse_pred_mode_y4(mbx)
        @pred_y4 = Array.new(4) { Array.new(4, 0) }
        4.times do |j|
          p = @left_mb[:pred][j]
          4.times do |i|
            prob = VP8Tables::PRED_PROB[@up_mb[mbx][:pred][i]][p]
            p = if !@fp.read_bit(prob[0])
                  PRED_DC
                elsif !@fp.read_bit(prob[1])
                  PRED_TM
                elsif !@fp.read_bit(prob[2])
                  PRED_VE
                elsif !@fp.read_bit(prob[3])
                  if !@fp.read_bit(prob[4])
                    PRED_HE
                  elsif !@fp.read_bit(prob[5])
                    PRED_RD
                  else
                    PRED_VR
                  end
                elsif !@fp.read_bit(prob[6])
                  PRED_LD
                elsif !@fp.read_bit(prob[7])
                  PRED_VL
                elsif !@fp.read_bit(prob[8])
                  PRED_HD
                else
                  PRED_HU
                end
            @pred_y4[j][i] = p
            @up_mb[mbx][:pred][i] = p
          end
          @left_mb[:pred][j] = p
        end
      end

      # ---- Residual parsing (reconstruct.go: parseResiduals / parseResiduals4) ----

      def parse_residuals(mbx)
        partition = @op[0]
        plane = PLANE_Y1_SANS_Y2
        q = @quant[@segment]

        if @use_pred_y16
          ctx = @left_mb[:nz_y16] + @up_mb[mbx][:nz_y16]
          nz = parse_residuals4(partition, PLANE_Y2, ctx, q[:y2], false, WHT_COEFF_BASE)
          @left_mb[:nz_y16] = nz
          @up_mb[mbx][:nz_y16] = nz
          inverse_wht16
          plane = PLANE_Y1_WITH_Y2
        end

        nz_dc_mask = 0
        nz_ac_mask = 0
        coeff_base = 0
        lnz = unpack4(@left_mb[:nz_mask] & 0x0F)
        unz = unpack4(@up_mb[mbx][:nz_mask] & 0x0F)
        4.times do |y|
          nz = lnz[y]
          nz_ac = [0, 0, 0, 0]
          nz_dc = [0, 0, 0, 0]
          4.times do |x|
            nz = parse_residuals4(partition, plane, nz + unz[x], q[:y1], @use_pred_y16, coeff_base)
            unz[x] = nz
            nz_ac[x] = nz
            nz_dc[x] = (@coeff[coeff_base] != 0) ? 1 : 0
            coeff_base += 16
          end
          lnz[y] = nz
          nz_dc_mask |= pack4(nz_dc, y * 4)
          nz_ac_mask |= pack4(nz_ac, y * 4)
        end
        lnz_mask = pack4(lnz, 0)
        unz_mask = pack4(unz, 0)

        lnz = unpack4(@left_mb[:nz_mask] >> 4)
        unz = unpack4(@up_mb[mbx][:nz_mask] >> 4)
        ch = 0
        while ch < 4
          nz_ac = [0, 0, 0, 0]
          nz_dc = [0, 0, 0, 0]
          2.times do |y|
            nz = lnz[y + ch]
            2.times do |x|
              nz = parse_residuals4(partition, PLANE_UV, nz + unz[x + ch], q[:uv], false, coeff_base)
              unz[x + ch] = nz
              nz_ac[y * 2 + x] = nz
              nz_dc[y * 2 + x] = (@coeff[coeff_base] != 0) ? 1 : 0
              coeff_base += 16
            end
            lnz[y + ch] = nz
          end
          nz_dc_mask |= pack4(nz_dc, 16 + ch * 2)
          nz_ac_mask |= pack4(nz_ac, 16 + ch * 2)
          ch += 2
        end
        lnz_mask |= pack4(lnz, 4)
        unz_mask |= pack4(unz, 4)

        @left_mb[:nz_mask] = lnz_mask & 0xFF
        @up_mb[mbx][:nz_mask] = unz_mask & 0xFF
        @nz_dc_mask = nz_dc_mask
        @nz_ac_mask = nz_ac_mask
      end

      def parse_residuals4(r, plane, context, quant, skip_first_coeff, coeff_base)
        prob = @token_prob[plane]
        n = skip_first_coeff ? 1 : 0
        p = prob[VP8Tables::BANDS[n]][context]
        return 0 unless r.read_bit(p[0])

        loop do
          break if n == 16

          n += 1
          unless r.read_bit(p[1])
            # DCT_0
            p = prob[VP8Tables::BANDS[n]][0]
            next
          end
          v = if !r.read_bit(p[2])
                p = prob[VP8Tables::BANDS[n]][1]
                1
              else
                large = if !r.read_bit(p[3])
                          if !r.read_bit(p[4])
                            2
                          else
                            3 + r.read_uint(p[5], 1)
                          end
                        elsif !r.read_bit(p[6])
                          if !r.read_bit(p[7])
                            5 + r.read_uint(159, 1) # CAT1
                          else
                            7 + 2 * r.read_uint(165, 1) + r.read_uint(145, 1) # CAT2
                          end
                        else
                          b1 = r.read_uint(p[8], 1)
                          b0 = r.read_uint(p[9 + b1], 1)
                          cat = 2 * b1 + b0
                          tab = VP8Tables::CAT3456[cat]
                          accum = 0
                          i = 0
                          while tab[i] != 0
                            accum = accum * 2 + r.read_uint(tab[i], 1)
                            i += 1
                          end
                          accum + 3 + (8 << cat)
                        end
                p = prob[VP8Tables::BANDS[n]][2]
                large
              end
          z = VP8Tables::ZIGZAG[n - 1]
          c = v * quant[z.positive? ? 1 : 0]
          c = -c if r.read_bit(UNIFORM_PROB)
          @coeff[coeff_base + z] = c
          return 1 if n == 16 || !r.read_bit(p[0])
        end
        1
      end

      # ---- Reconstruct macroblock (reconstruct.go: reconstructMacroblock) ----

      def reconstruct_macroblock(mbx, mby)
        if @use_pred_y16
          p = check_top_left_pred(mbx, mby, @pred_y16)
          call_pred16(p, 1, 8)
          4.times do |j|
            4.times do |i|
              n = 4 * j + i
              y = 4 * j + 1
              x = 4 * i + 8
              mask = 1 << n
              if (@nz_ac_mask & mask) != 0
                inverse_dct4(y, x, 16 * n)
              elsif (@nz_dc_mask & mask) != 0
                inverse_dct4_dc_only(y, x, 16 * n)
              end
            end
          end
        else
          4.times do |j|
            4.times do |i|
              n = 4 * j + i
              y = 4 * j + 1
              x = 4 * i + 8
              call_pred4(@pred_y4[j][i], y, x)
              mask = 1 << n
              if (@nz_ac_mask & mask) != 0
                inverse_dct4(y, x, 16 * n)
              elsif (@nz_dc_mask & mask) != 0
                inverse_dct4_dc_only(y, x, 16 * n)
              end
            end
          end
        end
        p = check_top_left_pred(mbx, mby, @pred_c8)
        call_pred8(p, YBR_B_Y, YBR_B_X)
        if (@nz_ac_mask & 0x0F0000) != 0
          inverse_dct8(YBR_B_Y, YBR_B_X, B_COEFF_BASE)
        elsif (@nz_dc_mask & 0x0F0000) != 0
          inverse_dct8_dc_only(YBR_B_Y, YBR_B_X, B_COEFF_BASE)
        end
        call_pred8(p, YBR_R_Y, YBR_R_X)
        if (@nz_ac_mask & 0xF00000) != 0
          inverse_dct8(YBR_R_Y, YBR_R_X, R_COEFF_BASE)
        elsif (@nz_dc_mask & 0xF00000) != 0
          inverse_dct8_dc_only(YBR_R_Y, YBR_R_X, R_COEFF_BASE)
        end
      end

      def check_top_left_pred(mbx, mby, p)
        return p if p != PRED_DC

        if mbx.zero?
          mby.zero? ? PRED_DC_TOPLEFT : PRED_DC_LEFT
        elsif mby.zero?
          PRED_DC_TOP
        else
          PRED_DC
        end
      end

      def copy_ybr_to_image(mbx, mby)
        16.times do |y|
          off = ((mby * 16) + y) * @y_stride + (mbx * 16)
          src = @ybr[YBR_Y_Y + y]
          16.times { |i| @img_y[off + i] = src[YBR_Y_X + i] }
        end
        8.times do |y|
          off = ((mby * 8) + y) * @c_stride + (mbx * 8)
          srcb = @ybr[YBR_B_Y + y]
          srcr = @ybr[YBR_R_Y + y]
          8.times do |i|
            @img_cb[off + i] = srcb[YBR_B_X + i]
            @img_cr[off + i] = srcr[YBR_R_X + i]
          end
        end
      end

      # ---- IDCT + WHT (idct.go) ----

      def inverse_dct4(y, x, coeff_base)
        m = Array.new(4) { Array.new(4, 0) }
        4.times do |i|
          a = @coeff[coeff_base + 0] + @coeff[coeff_base + 8]
          b = @coeff[coeff_base + 0] - @coeff[coeff_base + 8]
          c = ((@coeff[coeff_base + 4] * 35_468) >> 16) - ((@coeff[coeff_base + 12] * 85_627) >> 16)
          d = ((@coeff[coeff_base + 4] * 85_627) >> 16) + ((@coeff[coeff_base + 12] * 35_468) >> 16)
          m[i][0] = a + d
          m[i][1] = b + c
          m[i][2] = b - c
          m[i][3] = a - d
          coeff_base += 1
        end
        4.times do |j|
          dc = m[0][j] + 4
          a = dc + m[2][j]
          b = dc - m[2][j]
          c = ((m[1][j] * 35_468) >> 16) - ((m[3][j] * 85_627) >> 16)
          d = ((m[1][j] * 85_627) >> 16) + ((m[3][j] * 35_468) >> 16)
          @ybr[y + j][x + 0] = clip8(@ybr[y + j][x + 0] + ((a + d) >> 3))
          @ybr[y + j][x + 1] = clip8(@ybr[y + j][x + 1] + ((b + c) >> 3))
          @ybr[y + j][x + 2] = clip8(@ybr[y + j][x + 2] + ((b - c) >> 3))
          @ybr[y + j][x + 3] = clip8(@ybr[y + j][x + 3] + ((a - d) >> 3))
        end
      end

      def inverse_dct4_dc_only(y, x, coeff_base)
        dc = (@coeff[coeff_base] + 4) >> 3
        4.times { |j| 4.times { |i| @ybr[y + j][x + i] = clip8(@ybr[y + j][x + i] + dc) } }
      end

      def inverse_dct8(y, x, coeff_base)
        inverse_dct4(y + 0, x + 0, coeff_base + 0)
        inverse_dct4(y + 0, x + 4, coeff_base + 16)
        inverse_dct4(y + 4, x + 0, coeff_base + 32)
        inverse_dct4(y + 4, x + 4, coeff_base + 48)
      end

      def inverse_dct8_dc_only(y, x, coeff_base)
        inverse_dct4_dc_only(y + 0, x + 0, coeff_base + 0)
        inverse_dct4_dc_only(y + 0, x + 4, coeff_base + 16)
        inverse_dct4_dc_only(y + 4, x + 0, coeff_base + 32)
        inverse_dct4_dc_only(y + 4, x + 4, coeff_base + 48)
      end

      def inverse_wht16
        m = Array.new(16, 0)
        4.times do |i|
          a0 = @coeff[WHT_COEFF_BASE + 0 + i] + @coeff[WHT_COEFF_BASE + 12 + i]
          a1 = @coeff[WHT_COEFF_BASE + 4 + i] + @coeff[WHT_COEFF_BASE + 8 + i]
          a2 = @coeff[WHT_COEFF_BASE + 4 + i] - @coeff[WHT_COEFF_BASE + 8 + i]
          a3 = @coeff[WHT_COEFF_BASE + 0 + i] - @coeff[WHT_COEFF_BASE + 12 + i]
          m[0 + i]  = a0 + a1
          m[8 + i]  = a0 - a1
          m[4 + i]  = a3 + a2
          m[12 + i] = a3 - a2
        end
        out = 0
        4.times do |i|
          dc = m[0 + i * 4] + 3
          a0 = dc + m[3 + i * 4]
          a1 = m[1 + i * 4] + m[2 + i * 4]
          a2 = m[1 + i * 4] - m[2 + i * 4]
          a3 = dc - m[3 + i * 4]
          @coeff[out + 0]  = (a0 + a1) >> 3
          @coeff[out + 16] = (a3 + a2) >> 3
          @coeff[out + 32] = (a0 - a1) >> 3
          @coeff[out + 48] = (a3 - a2) >> 3
          out += 64
        end
      end

      # ---- Intra prediction (predfunc.go) ----

      def call_pred4(p, y, x)
        case p
        when PRED_DC then pred4_dc(y, x)
        when PRED_TM then pred4_tm(y, x)
        when PRED_VE then pred4_ve(y, x)
        when PRED_HE then pred4_he(y, x)
        when PRED_RD then pred4_rd(y, x)
        when PRED_VR then pred4_vr(y, x)
        when PRED_LD then pred4_ld(y, x)
        when PRED_VL then pred4_vl(y, x)
        when PRED_HD then pred4_hd(y, x)
        when PRED_HU then pred4_hu(y, x)
        else raise DecodeError, "bad pred4 mode: #{p}"
        end
      end

      def call_pred8(p, y, x)
        case p
        when PRED_DC         then pred8_dc(y, x)
        when PRED_TM         then pred8_tm(y, x)
        when PRED_VE         then pred8_ve(y, x)
        when PRED_HE         then pred8_he(y, x)
        when PRED_DC_TOP     then pred8_dc_top(y, x)
        when PRED_DC_LEFT    then pred8_dc_left(y, x)
        when PRED_DC_TOPLEFT then pred8_dc_topleft(y, x)
        else raise DecodeError, "bad pred8 mode: #{p}"
        end
      end

      def call_pred16(p, y, x)
        case p
        when PRED_DC         then pred16_dc(y, x)
        when PRED_TM         then pred16_tm(y, x)
        when PRED_VE         then pred16_ve(y, x)
        when PRED_HE         then pred16_he(y, x)
        when PRED_DC_TOP     then pred16_dc_top(y, x)
        when PRED_DC_LEFT    then pred16_dc_left(y, x)
        when PRED_DC_TOPLEFT then pred16_dc_topleft(y, x)
        else raise DecodeError, "bad pred16 mode: #{p}"
        end
      end

      # 4x4 predictors
      def pred4_dc(y, x)
        sum = 4
        4.times { |i| sum += @ybr[y - 1][x + i] }
        4.times { |j| sum += @ybr[y + j][x - 1] }
        avg = sum >> 3
        4.times { |j| 4.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred4_tm(y, x)
        d0 = -@ybr[y - 1][x - 1]
        4.times do |j|
          d1 = d0 + @ybr[y + j][x - 1]
          4.times do |i|
            @ybr[y + j][x + i] = clip8(d1 + @ybr[y - 1][x + i])
          end
        end
      end

      def pred4_ve(y, x)
        a = @ybr[y - 1][x - 1]
        b = @ybr[y - 1][x + 0]
        c = @ybr[y - 1][x + 1]
        d = @ybr[y - 1][x + 2]
        e = @ybr[y - 1][x + 3]
        f = @ybr[y - 1][x + 4]
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        cde = (c + (2 * d) + e + 2) >> 2
        def_ = (d + (2 * e) + f + 2) >> 2
        4.times do |j|
          @ybr[y + j][x + 0] = abc
          @ybr[y + j][x + 1] = bcd
          @ybr[y + j][x + 2] = cde
          @ybr[y + j][x + 3] = def_
        end
      end

      def pred4_he(y, x)
        s = @ybr[y + 3][x - 1]
        r = @ybr[y + 2][x - 1]
        q = @ybr[y + 1][x - 1]
        p = @ybr[y + 0][x - 1]
        a = @ybr[y - 1][x - 1]
        ssr = (s + (2 * s) + r + 2) >> 2
        srq = (s + (2 * r) + q + 2) >> 2
        rqp = (r + (2 * q) + p + 2) >> 2
        apq = (a + (2 * p) + q + 2) >> 2
        4.times do |i|
          @ybr[y + 0][x + i] = apq
          @ybr[y + 1][x + i] = rqp
          @ybr[y + 2][x + i] = srq
          @ybr[y + 3][x + i] = ssr
        end
      end

      def pred4_rd(y, x)
        s = @ybr[y + 3][x - 1]
        r = @ybr[y + 2][x - 1]
        q = @ybr[y + 1][x - 1]
        p = @ybr[y + 0][x - 1]
        a = @ybr[y - 1][x - 1]
        b = @ybr[y - 1][x + 0]
        c = @ybr[y - 1][x + 1]
        d = @ybr[y - 1][x + 2]
        e = @ybr[y - 1][x + 3]
        srq = (s + (2 * r) + q + 2) >> 2
        rqp = (r + (2 * q) + p + 2) >> 2
        qpa = (q + (2 * p) + a + 2) >> 2
        pab = (p + (2 * a) + b + 2) >> 2
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        cde = (c + (2 * d) + e + 2) >> 2
        @ybr[y + 0][x + 0] = pab; @ybr[y + 0][x + 1] = abc; @ybr[y + 0][x + 2] = bcd; @ybr[y + 0][x + 3] = cde
        @ybr[y + 1][x + 0] = qpa; @ybr[y + 1][x + 1] = pab; @ybr[y + 1][x + 2] = abc; @ybr[y + 1][x + 3] = bcd
        @ybr[y + 2][x + 0] = rqp; @ybr[y + 2][x + 1] = qpa; @ybr[y + 2][x + 2] = pab; @ybr[y + 2][x + 3] = abc
        @ybr[y + 3][x + 0] = srq; @ybr[y + 3][x + 1] = rqp; @ybr[y + 3][x + 2] = qpa; @ybr[y + 3][x + 3] = pab
      end

      def pred4_vr(y, x)
        r = @ybr[y + 2][x - 1]
        q = @ybr[y + 1][x - 1]
        p = @ybr[y + 0][x - 1]
        a = @ybr[y - 1][x - 1]
        b = @ybr[y - 1][x + 0]
        c = @ybr[y - 1][x + 1]
        d = @ybr[y - 1][x + 2]
        e = @ybr[y - 1][x + 3]
        ab = (a + b + 1) >> 1
        bc = (b + c + 1) >> 1
        cd = (c + d + 1) >> 1
        de = (d + e + 1) >> 1
        rqp = (r + (2 * q) + p + 2) >> 2
        qpa = (q + (2 * p) + a + 2) >> 2
        pab = (p + (2 * a) + b + 2) >> 2
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        cde = (c + (2 * d) + e + 2) >> 2
        @ybr[y + 0][x + 0] = ab;  @ybr[y + 0][x + 1] = bc;  @ybr[y + 0][x + 2] = cd;  @ybr[y + 0][x + 3] = de
        @ybr[y + 1][x + 0] = pab; @ybr[y + 1][x + 1] = abc; @ybr[y + 1][x + 2] = bcd; @ybr[y + 1][x + 3] = cde
        @ybr[y + 2][x + 0] = qpa; @ybr[y + 2][x + 1] = ab;  @ybr[y + 2][x + 2] = bc;  @ybr[y + 2][x + 3] = cd
        @ybr[y + 3][x + 0] = rqp; @ybr[y + 3][x + 1] = pab; @ybr[y + 3][x + 2] = abc; @ybr[y + 3][x + 3] = bcd
      end

      def pred4_ld(y, x)
        a = @ybr[y - 1][x + 0]; b = @ybr[y - 1][x + 1]; c = @ybr[y - 1][x + 2]; d = @ybr[y - 1][x + 3]
        e = @ybr[y - 1][x + 4]; f = @ybr[y - 1][x + 5]; g = @ybr[y - 1][x + 6]; h = @ybr[y - 1][x + 7]
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        cde = (c + (2 * d) + e + 2) >> 2
        def_ = (d + (2 * e) + f + 2) >> 2
        efg = (e + (2 * f) + g + 2) >> 2
        fgh = (f + (2 * g) + h + 2) >> 2
        ghh = (g + (2 * h) + h + 2) >> 2
        @ybr[y + 0][x + 0] = abc; @ybr[y + 0][x + 1] = bcd; @ybr[y + 0][x + 2] = cde; @ybr[y + 0][x + 3] = def_
        @ybr[y + 1][x + 0] = bcd; @ybr[y + 1][x + 1] = cde; @ybr[y + 1][x + 2] = def_; @ybr[y + 1][x + 3] = efg
        @ybr[y + 2][x + 0] = cde; @ybr[y + 2][x + 1] = def_; @ybr[y + 2][x + 2] = efg; @ybr[y + 2][x + 3] = fgh
        @ybr[y + 3][x + 0] = def_; @ybr[y + 3][x + 1] = efg; @ybr[y + 3][x + 2] = fgh; @ybr[y + 3][x + 3] = ghh
      end

      def pred4_vl(y, x)
        a = @ybr[y - 1][x + 0]; b = @ybr[y - 1][x + 1]; c = @ybr[y - 1][x + 2]; d = @ybr[y - 1][x + 3]
        e = @ybr[y - 1][x + 4]; f = @ybr[y - 1][x + 5]; g = @ybr[y - 1][x + 6]; h = @ybr[y - 1][x + 7]
        ab = (a + b + 1) >> 1
        bc = (b + c + 1) >> 1
        cd = (c + d + 1) >> 1
        de = (d + e + 1) >> 1
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        cde = (c + (2 * d) + e + 2) >> 2
        def_ = (d + (2 * e) + f + 2) >> 2
        efg = (e + (2 * f) + g + 2) >> 2
        fgh = (f + (2 * g) + h + 2) >> 2
        @ybr[y + 0][x + 0] = ab;  @ybr[y + 0][x + 1] = bc;  @ybr[y + 0][x + 2] = cd;  @ybr[y + 0][x + 3] = de
        @ybr[y + 1][x + 0] = abc; @ybr[y + 1][x + 1] = bcd; @ybr[y + 1][x + 2] = cde; @ybr[y + 1][x + 3] = def_
        @ybr[y + 2][x + 0] = bc;  @ybr[y + 2][x + 1] = cd;  @ybr[y + 2][x + 2] = de;  @ybr[y + 2][x + 3] = efg
        @ybr[y + 3][x + 0] = bcd; @ybr[y + 3][x + 1] = cde; @ybr[y + 3][x + 2] = def_; @ybr[y + 3][x + 3] = fgh
      end

      def pred4_hd(y, x)
        s = @ybr[y + 3][x - 1]; r = @ybr[y + 2][x - 1]; q = @ybr[y + 1][x - 1]; p = @ybr[y + 0][x - 1]
        a = @ybr[y - 1][x - 1]; b = @ybr[y - 1][x + 0]; c = @ybr[y - 1][x + 1]; d = @ybr[y - 1][x + 2]
        sr = (s + r + 1) >> 1
        rq = (r + q + 1) >> 1
        qp = (q + p + 1) >> 1
        pa = (p + a + 1) >> 1
        srq = (s + (2 * r) + q + 2) >> 2
        rqp = (r + (2 * q) + p + 2) >> 2
        qpa = (q + (2 * p) + a + 2) >> 2
        pab = (p + (2 * a) + b + 2) >> 2
        abc = (a + (2 * b) + c + 2) >> 2
        bcd = (b + (2 * c) + d + 2) >> 2
        @ybr[y + 0][x + 0] = pa;  @ybr[y + 0][x + 1] = pab; @ybr[y + 0][x + 2] = abc; @ybr[y + 0][x + 3] = bcd
        @ybr[y + 1][x + 0] = qp;  @ybr[y + 1][x + 1] = qpa; @ybr[y + 1][x + 2] = pa;  @ybr[y + 1][x + 3] = pab
        @ybr[y + 2][x + 0] = rq;  @ybr[y + 2][x + 1] = rqp; @ybr[y + 2][x + 2] = qp;  @ybr[y + 2][x + 3] = qpa
        @ybr[y + 3][x + 0] = sr;  @ybr[y + 3][x + 1] = srq; @ybr[y + 3][x + 2] = rq;  @ybr[y + 3][x + 3] = rqp
      end

      def pred4_hu(y, x)
        s = @ybr[y + 3][x - 1]; r = @ybr[y + 2][x - 1]; q = @ybr[y + 1][x - 1]; p = @ybr[y + 0][x - 1]
        pq = (p + q + 1) >> 1
        qr = (q + r + 1) >> 1
        rs = (r + s + 1) >> 1
        pqr = (p + (2 * q) + r + 2) >> 2
        qrs = (q + (2 * r) + s + 2) >> 2
        rss = (r + (2 * s) + s + 2) >> 2
        sss = s
        @ybr[y + 0][x + 0] = pq;  @ybr[y + 0][x + 1] = pqr; @ybr[y + 0][x + 2] = qr;  @ybr[y + 0][x + 3] = qrs
        @ybr[y + 1][x + 0] = qr;  @ybr[y + 1][x + 1] = qrs; @ybr[y + 1][x + 2] = rs;  @ybr[y + 1][x + 3] = rss
        @ybr[y + 2][x + 0] = rs;  @ybr[y + 2][x + 1] = rss; @ybr[y + 2][x + 2] = sss; @ybr[y + 2][x + 3] = sss
        @ybr[y + 3][x + 0] = sss; @ybr[y + 3][x + 1] = sss; @ybr[y + 3][x + 2] = sss; @ybr[y + 3][x + 3] = sss
      end

      # 8x8 chroma predictors
      def pred8_dc(y, x)
        sum = 8
        8.times { |i| sum += @ybr[y - 1][x + i] }
        8.times { |j| sum += @ybr[y + j][x - 1] }
        avg = sum >> 4
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred8_tm(y, x)
        d0 = -@ybr[y - 1][x - 1]
        8.times do |j|
          d1 = d0 + @ybr[y + j][x - 1]
          8.times { |i| @ybr[y + j][x + i] = clip8(d1 + @ybr[y - 1][x + i]) }
        end
      end

      def pred8_ve(y, x)
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = @ybr[y - 1][x + i] } }
      end

      def pred8_he(y, x)
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = @ybr[y + j][x - 1] } }
      end

      def pred8_dc_top(y, x)
        sum = 4
        8.times { |j| sum += @ybr[y + j][x - 1] }
        avg = sum >> 3
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred8_dc_left(y, x)
        sum = 4
        8.times { |i| sum += @ybr[y - 1][x + i] }
        avg = sum >> 3
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred8_dc_topleft(y, x)
        8.times { |j| 8.times { |i| @ybr[y + j][x + i] = 0x80 } }
      end

      # 16x16 luma predictors
      def pred16_dc(y, x)
        sum = 16
        16.times { |i| sum += @ybr[y - 1][x + i] }
        16.times { |j| sum += @ybr[y + j][x - 1] }
        avg = sum >> 5
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred16_tm(y, x)
        d0 = -@ybr[y - 1][x - 1]
        16.times do |j|
          d1 = d0 + @ybr[y + j][x - 1]
          16.times { |i| @ybr[y + j][x + i] = clip8(d1 + @ybr[y - 1][x + i]) }
        end
      end

      def pred16_ve(y, x)
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = @ybr[y - 1][x + i] } }
      end

      def pred16_he(y, x)
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = @ybr[y + j][x - 1] } }
      end

      def pred16_dc_top(y, x)
        sum = 8
        16.times { |j| sum += @ybr[y + j][x - 1] }
        avg = sum >> 4
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred16_dc_left(y, x)
        sum = 8
        16.times { |i| sum += @ybr[y - 1][x + i] }
        avg = sum >> 4
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = avg } }
      end

      def pred16_dc_topleft(y, x)
        16.times { |j| 16.times { |i| @ybr[y + j][x + i] = 0x80 } }
      end

      # ---- YUV 4:2:0 -> RGB (BT.601) ----

      def yuv_to_rgb_image
        pixels = String.new(encoding: Encoding::BINARY, capacity: @width * @height * 3)
        @height.times do |row|
          uv_row_base = (row / 2) * @c_stride
          y_row_base  = row * @y_stride
          @width.times do |col|
            y = @img_y[y_row_base + col]
            u = @img_cb[uv_row_base + (col / 2)]
            v = @img_cr[uv_row_base + (col / 2)]
            c = y - 16
            d = u - 128
            e = v - 128
            r = (((298 * c) + (409 * e) + 128) >> 8).clamp(0, 255)
            g = (((298 * c) - (100 * d) - (208 * e) + 128) >> 8).clamp(0, 255)
            b = (((298 * c) + (516 * d) + 128) >> 8).clamp(0, 255)
            pixels << r.chr << g.chr << b.chr
          end
        end
        Image.new(@width, @height, pixels)
      end

      # ---- Helpers ----

      def clip(x, lo, hi)
        x < lo ? lo : (x > hi ? hi : x)
      end

      def clip8(x)
        x < 0 ? 0 : (x > 255 ? 255 : x)
      end

      def pack4(arr, shift)
        u = arr[0] | (arr[1] << 1) | (arr[2] << 2) | (arr[3] << 3)
        u << shift
      end

      UNPACK4 = Array.new(16) { |i| [i & 1, (i >> 1) & 1, (i >> 2) & 1, (i >> 3) & 1] }.freeze

      def unpack4(nibble)
        UNPACK4[nibble & 0x0F].dup
      end

      # ---- Byte readers (outer RIFF parser) ----

      def read_u8
        raise DecodeError, "unexpected end of data" if @pos >= @data.bytesize

        val = @data.getbyte(@pos)
        @pos += 1
        val
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

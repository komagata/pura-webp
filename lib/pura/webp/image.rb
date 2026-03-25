# frozen_string_literal: true

module Pura
  module Webp
    class Image
      attr_reader :width, :height, :pixels

      def initialize(width, height, pixels)
        @width = width
        @height = height
        @pixels = pixels.b
        expected = width * height * 3
        return if @pixels.bytesize == expected

        raise ArgumentError, "pixel data size #{@pixels.bytesize} != expected #{expected} (#{width}x#{height}x3)"
      end

      def to_rgb_array
        result = Array.new(width * height)
        i = 0
        offset = 0
        while offset < @pixels.bytesize
          result[i] = [@pixels.getbyte(offset), @pixels.getbyte(offset + 1), @pixels.getbyte(offset + 2)]
          i += 1
          offset += 3
        end
        result
      end

      def pixel_at(x, y)
        raise IndexError, "coordinates out of bounds" if x.negative? || x >= @width || y.negative? || y >= @height

        offset = ((y * @width) + x) * 3
        [@pixels.getbyte(offset), @pixels.getbyte(offset + 1), @pixels.getbyte(offset + 2)]
      end

      def to_ppm
        header = "P6\n#{@width} #{@height}\n255\n"
        header.b + @pixels
      end

      def resize(new_width, new_height, interpolation: :bilinear)
        raise ArgumentError, "width must be positive" unless new_width.positive?
        raise ArgumentError, "height must be positive" unless new_height.positive?

        if interpolation == :nearest
          resize_nearest(new_width, new_height)
        else
          resize_bilinear(new_width, new_height)
        end
      end

      def resize_fit(max_width, max_height, interpolation: :bilinear)
        raise ArgumentError, "max_width must be positive" unless max_width.positive?
        raise ArgumentError, "max_height must be positive" unless max_height.positive?

        scale = [max_width.to_f / @width, max_height.to_f / @height].min
        scale = [scale, 1.0].min
        new_width = (@width * scale).round
        new_height = (@height * scale).round
        new_width = 1 if new_width < 1
        new_height = 1 if new_height < 1
        resize(new_width, new_height, interpolation: interpolation)
      end

      def resize_fill(fill_width, fill_height, interpolation: :bilinear)
        raise ArgumentError, "width must be positive" unless fill_width.positive?
        raise ArgumentError, "height must be positive" unless fill_height.positive?

        scale = [fill_width.to_f / @width, fill_height.to_f / @height].max
        scaled_w = (@width * scale).round
        scaled_h = (@height * scale).round
        scaled_w = 1 if scaled_w < 1
        scaled_h = 1 if scaled_h < 1

        scaled = resize(scaled_w, scaled_h, interpolation: interpolation)

        crop_x = (scaled_w - fill_width) / 2
        crop_y = (scaled_h - fill_height) / 2
        scaled.crop(crop_x, crop_y, fill_width, fill_height)
      end

      def crop(x, y, w, h)
        out = String.new(encoding: Encoding::BINARY, capacity: w * h * 3)
        h.times do |row|
          src_offset = (((y + row) * @width) + x) * 3
          out << @pixels.byteslice(src_offset, w * 3)
        end
        Image.new(w, h, out)
      end

      private

      def resize_nearest(new_width, new_height)
        out = String.new(encoding: Encoding::BINARY, capacity: new_width * new_height * 3)
        x_ratio = @width.to_f / new_width
        y_ratio = @height.to_f / new_height

        new_height.times do |y|
          src_y = (y * y_ratio).to_i
          src_y = @height - 1 if src_y >= @height
          new_width.times do |x|
            src_x = (x * x_ratio).to_i
            src_x = @width - 1 if src_x >= @width
            offset = ((src_y * @width) + src_x) * 3
            out << @pixels.byteslice(offset, 3)
          end
        end

        Image.new(new_width, new_height, out)
      end

      def resize_bilinear(new_width, new_height)
        out = String.new(encoding: Encoding::BINARY, capacity: new_width * new_height * 3)
        x_ratio = (@width - 1).to_f / [new_width - 1, 1].max
        y_ratio = (@height - 1).to_f / [new_height - 1, 1].max

        new_height.times do |y|
          src_y = y * y_ratio
          y0 = src_y.to_i
          y1 = [y0 + 1, @height - 1].min
          y_frac = src_y - y0

          new_width.times do |x|
            src_x = x * x_ratio
            x0 = src_x.to_i
            x1 = [x0 + 1, @width - 1].min
            x_frac = src_x - x0

            off00 = ((y0 * @width) + x0) * 3
            off10 = ((y0 * @width) + x1) * 3
            off01 = ((y1 * @width) + x0) * 3
            off11 = ((y1 * @width) + x1) * 3

            3.times do |c|
              v00 = @pixels.getbyte(off00 + c)
              v10 = @pixels.getbyte(off10 + c)
              v01 = @pixels.getbyte(off01 + c)
              v11 = @pixels.getbyte(off11 + c)

              val = (v00 * (1 - x_frac) * (1 - y_frac)) +
                    (v10 * x_frac * (1 - y_frac)) +
                    (v01 * (1 - x_frac) * y_frac) +
                    (v11 * x_frac * y_frac)

              val = val.round
              val = 0 if val.negative?
              val = 255 if val > 255
              out << val.chr
            end
          end
        end

        Image.new(new_width, new_height, out)
      end
    end
  end
end

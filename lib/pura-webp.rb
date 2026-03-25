# frozen_string_literal: true

require_relative "pura/webp/version"
require_relative "pura/webp/image"
require_relative "pura/webp/bool_decoder"
require_relative "pura/webp/vp8_tables"
require_relative "pura/webp/decoder"
require_relative "pura/webp/encoder"

module Pura
  module Webp
    def self.decode(input)
      Decoder.decode(input)
    end

    def self.encode(image, output_path)
      Encoder.encode(image, output_path)
    end
  end
end

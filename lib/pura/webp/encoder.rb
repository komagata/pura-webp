# frozen_string_literal: true

module Pura
  module Webp
    class Encoder
      def self.encode(_image, _path, **_options)
        raise NotImplementedError, "WebP encoding is not yet supported"
      end
    end
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/pura-webp"

class TestCropBounds < Minitest::Test
  def setup
    @image = Pura::Webp::Image.new(2, 2, [255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255].pack("C*"))
  end

  def test_crop_preserves_the_requested_pixels
    assert_equal [[0, 255, 0], [255, 255, 255]], @image.crop(1, 0, 1, 2).to_rgb_array
  end

  def test_crop_rejects_regions_outside_the_image
    [[1, 0, 2, 1], [0, 1, 1, 2], [-1, 0, 1, 1], [0, -1, 1, 1]].each do |region|
      assert_raises(ArgumentError, region.inspect) { @image.crop(*region) }
    end
  end

  def test_crop_rejects_empty_or_noninteger_regions
    [[0, 0, 0, 1], [0, 0, 1, 0], [0, 0, -1, 1], [0.5, 0, 1, 1], [0, 0, 1.5, 1]].each do |region|
      assert_raises(ArgumentError, region.inspect) { @image.crop(*region) }
    end
  end
end

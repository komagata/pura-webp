# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/pura-webp"

class TestDecoder < Minitest::Test
  FIXTURE_DIR = File.join(__dir__, "fixtures")

  # Phase 0: RIFF parsing
  def test_rejects_non_riff
    assert_raises(Pura::Webp::DecodeError) { Pura::Webp.decode("NOT_RIFF_DATA") }
  end

  def test_rejects_non_webp_riff
    data = "RIFF\x00\x00\x00\x00AVI "
    assert_raises(Pura::Webp::DecodeError) { Pura::Webp.decode(data) }
  end

  # Phase 1: VP8 frame header — dimensions
  def test_decode_64x64_dimensions
    path = File.join(FIXTURE_DIR, "test_64x64.webp")
    image = Pura::Webp.decode(path)

    assert_equal 64, image.width
    assert_equal 64, image.height
    assert_equal 64 * 64 * 3, image.pixels.bytesize
  end

  def test_decode_16x16_dimensions
    path = File.join(FIXTURE_DIR, "test_16x16.webp")
    image = Pura::Webp.decode(path)

    assert_equal 16, image.width
    assert_equal 16, image.height
  end

  # Image class methods work
  def test_pixel_at
    path = File.join(FIXTURE_DIR, "test_16x16.webp")
    image = Pura::Webp.decode(path)

    r, g, b = image.pixel_at(0, 0)
    assert_kind_of Integer, r
    assert_kind_of Integer, g
    assert_kind_of Integer, b
  end

  def test_version
    assert_match(/\d+\.\d+\.\d+/, Pura::Webp::VERSION)
  end
end

# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/pura-webp"

class TestEncoder < Minitest::Test
  def test_encode_solid_color
    pixels = "\xFF\x00\x00".b * 16
    img = Pura::Webp::Image.new(4, 4, pixels)
    Pura::Webp.encode(img, "/tmp/test_enc_solid.webp")

    assert File.exist?("/tmp/test_enc_solid.webp")
    data = File.binread("/tmp/test_enc_solid.webp")
    assert_equal "RIFF", data[0..3]
    assert_equal "WEBP", data[8..11]
    assert_equal "VP8L", data[12..15]
  end

  def test_encode_two_colors
    skip "dwebp not installed — install libwebp to run this test" unless dwebp_available?
    pixels = String.new(encoding: Encoding::BINARY)
    4.times do |y|
      4.times do |x|
        if (x + y).even?
          pixels << 255.chr << 0.chr << 0.chr
        else
          pixels << 0.chr << 255.chr << 0.chr
        end
      end
    end
    img = Pura::Webp::Image.new(4, 4, pixels)
    Pura::Webp.encode(img, "/tmp/test_enc_2colors.webp")

    assert File.exist?("/tmp/test_enc_2colors.webp")
    assert dwebp_valid?("/tmp/test_enc_2colors.webp")
  end

  def test_encode_gradient
    skip "dwebp not installed — install libwebp to run this test" unless dwebp_available?
    pixels = String.new(encoding: Encoding::BINARY)
    16.times do |y|
      16.times do |x|
        pixels << (x * 16).chr << (y * 16).chr << 128.chr
      end
    end
    img = Pura::Webp::Image.new(16, 16, pixels)
    Pura::Webp.encode(img, "/tmp/test_enc_gradient.webp")

    assert dwebp_valid?("/tmp/test_enc_gradient.webp")
  end

  def test_encode_32x32
    skip "dwebp not installed — install libwebp to run this test" unless dwebp_available?
    pixels = String.new(encoding: Encoding::BINARY)
    32.times do |y|
      32.times do |x|
        pixels << (x * 8).chr << (y * 8).chr << ((x + y) * 4).chr
      end
    end
    img = Pura::Webp::Image.new(32, 32, pixels)
    Pura::Webp.encode(img, "/tmp/test_enc_32.webp")

    assert dwebp_valid?("/tmp/test_enc_32.webp")
  end

  def test_encode_returns_size
    pixels = "\x80\x80\x80".b * 4
    img = Pura::Webp::Image.new(2, 2, pixels)
    size = Pura::Webp.encode(img, "/tmp/test_enc_size.webp")

    assert_kind_of Integer, size
    assert_equal File.size("/tmp/test_enc_size.webp"), size
  end

  def test_encoder_stub_removed
    pixels = "\xFF\xFF\xFF".b * 4
    img = Pura::Webp::Image.new(2, 2, pixels)
    Pura::Webp.encode(img, "/tmp/test_enc_nostub.webp")
    assert File.exist?("/tmp/test_enc_nostub.webp")
  end

  private

  def dwebp_available?
    system("which dwebp > /dev/null 2>&1")
  end

  def dwebp_valid?(path)
    dwebp_available? && system("dwebp #{path} -o /dev/null 2>/dev/null")
  end
end

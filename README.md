# pura-webp

Pure Ruby WebP decoder/encoder. Part of the pura-* series.

## Features

- **VP8 lossy decoding** — Boolean arithmetic decoder, DCT/WHT transforms, intra prediction, loop filter
- **VP8L lossless encoding** — Huffman coding, subtract-green transform, RIFF container
- **Image operations** — resize, resize_fit, resize_fill, crop, pixel_at, to_ppm
- **Pure Ruby** — Zero C extensions, zero dependencies
- **Ruby 3.0+** compatible

## Installation

```ruby
gem 'pura-webp'
```

## Usage

### Decode a WebP file

```ruby
require "pura-webp"

image = Pura::Webp.decode("photo.webp")
puts "#{image.width}x#{image.height}"
pixel = image.pixel_at(0, 0) # => [r, g, b]
```

### Encode to WebP (lossless)

```ruby
require "pura-webp"

image = Pura::Webp.decode("input.webp")
Pura::Webp.encode(image, "output.webp")
```

### Resize

```ruby
resized = image.resize(320, 240)
fitted = image.resize_fit(100, 100)
filled = image.resize_fill(100, 100)
cropped = image.crop(10, 10, 50, 50)
```

### Export to PPM

```ruby
File.binwrite("output.ppm", image.to_ppm)
```

## Why pure Ruby?

- `gem install` just works — no compiler, no native libraries
- Cross-platform: macOS, Linux, Windows, even WebAssembly
- Perfect for dev tools, CI pipelines, and serverless

## Related gems

- [pura-jpeg](https://github.com/komagata/pura-jpeg) — Pure Ruby JPEG decoder/encoder
- [pura-png](https://github.com/komagata/pura-png) — Pure Ruby PNG decoder/encoder

## License

MIT

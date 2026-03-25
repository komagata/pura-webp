# pura-webp

A pure Ruby WebP decoder/encoder with zero C extension dependencies.

Part of the **pura-*** series — pure Ruby image codec gems.

## Features

- **VP8 lossy decoding** — Boolean arithmetic decoder, DCT/WHT transforms, intra prediction, loop filter
- **VP8L lossless encoding** — Huffman coding, subtract-green transform, RIFF container
- **Image operations** — resize, resize_fit, resize_fill, crop, pixel_at, to_ppm
- **Pure Ruby** — Zero C extensions, zero dependencies
- **Ruby 3.0+** compatible

## Installation

```bash
gem install pura-webp
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

## Benchmark

400×400 image, Ruby 4.0.2 + YJIT.

### Decode (VP8 lossy)

| Decoder | Time |
|---------|------|
| ffmpeg (C) | 66 ms |
| **pura-webp** | **207 ms** |

No other pure scripting-language WebP decoder exists. Lossy encoder coming soon.

## Why pure Ruby?

- **`gem install` and go** — no compiler, no native libraries
- **Cross-platform** — macOS, Linux, Windows, even WebAssembly
- **Perfect for dev tools, CI pipelines, and serverless**
- **Part of pura-\*** — convert between JPEG, PNG, BMP, GIF, TIFF, WebP seamlessly

## Related gems

| Gem | Format | Status |
|-----|--------|--------|
| [pura-jpeg](https://github.com/komagata/pura-jpeg) | JPEG | ✅ Available |
| [pura-png](https://github.com/komagata/pura-png) | PNG | ✅ Available |
| [pura-bmp](https://github.com/komagata/pura-bmp) | BMP | ✅ Available |
| [pura-gif](https://github.com/komagata/pura-gif) | GIF | ✅ Available |
| [pura-tiff](https://github.com/komagata/pura-tiff) | TIFF | ✅ Available |
| [pura-ico](https://github.com/komagata/pura-ico) | ICO | ✅ Available |
| **pura-webp** | WebP | ✅ Available |
| [pura-image](https://github.com/komagata/pura-image) | All formats | ✅ Available |

## License

MIT

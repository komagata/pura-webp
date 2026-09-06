# pura-webp

A pure Ruby WebP decoder and encoder without additional image-processing libraries.

Part of the **pura-*** series — pure Ruby image codec gems.

## Features

- VP8 lossy WebP decoding
- VP8L lossless WebP encoding
- No image-specific native extension or FFI dependency
- CLI tool included

## Installation

```bash
gem install pura-webp
```

## Usage

```ruby
require "pura-webp"

# Decode
image = Pura::Webp.decode("photo.webp")
image.width      #=> 800
image.height     #=> 600
image.pixels     #=> Raw RGB byte string
image.pixel_at(0, 0) #=> [r, g, b]

# Encode (VP8L lossless)
Pura::Webp.encode(image, "output.webp")

# Resize
thumb = image.resize(200, 200)
Pura::Webp.encode(thumb, "thumb.webp")
```

## Benchmark

These historical measurements include ffmpeg process startup. They do not compare against an in-process C codec or establish Rails pipeline throughput.

Decode performance on a 400×400 WebP image, Ruby 4.0.2 + YJIT:

| Operation | pura-webp | ffmpeg (C + SIMD) | vs ffmpeg |
|-----------|-----------|-------------------|-----------|
| Decode | 207 ms | 66 ms | 3.1× slower |

## Why pure Ruby?

- **`gem install` and go** — no `brew install webp`, no `apt install libwebp-dev`
- **No system library needed** — unlike every other Ruby WebP solution

## Current Limitations

- Decoder: VP8 lossy only (VP8L lossless and VP8X extended not yet decoded)
- Encoder: VP8L lossless format, works best with images up to ~200×200
- Loop filter not implemented in decoder (slight quality difference)

## Related Gems

| Gem | Format | Status |
|-----|--------|--------|
| [pura-jpeg](https://github.com/komagata/pura-jpeg) | JPEG | ✅ |
| [pura-png](https://github.com/komagata/pura-png) | PNG | ✅ |
| [pura-bmp](https://github.com/komagata/pura-bmp) | BMP | ✅ |
| [pura-gif](https://github.com/komagata/pura-gif) | GIF | ✅ |
| [pura-tiff](https://github.com/komagata/pura-tiff) | TIFF | ✅ |
| [pura-ico](https://github.com/komagata/pura-ico) | ICO | ✅ |
| **pura-webp** | **WebP** | ✅ |
| [pura-image](https://github.com/komagata/pura-image) | All formats | ✅ |

## Pixel model and limitations

Images contain 8-bit RGB pixels. The encoder produces VP8L, which this decoder cannot read back yet. Decoded pixels are RGB and do not retain alpha. Multi-partition VP8 frames are also unsupported.

`crop(x, y, width, height)` requires integer coordinates, positive dimensions, and a region entirely inside the image; invalid regions raise `ArgumentError`.

## License

MIT — see [LICENSE](LICENSE).

The VP8 decoder is a Ruby port of the Go package
[golang.org/x/image/vp8](https://pkg.go.dev/golang.org/x/image/vp8),
which is distributed under the BSD-3-Clause license. See
[LICENSE-GO](LICENSE-GO) for that notice. The Go copyright is retained
on the ported files as required.

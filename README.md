# SSIM Playground

Web UI for comparing images using SSIM, Delta E, and pixel-level diff algorithms.

## Setup

Install libvips:

```bash
# macOS
brew install vips

```

Then:

```bash
bundle install
bundle exec ruby app.rb
```

Open http://localhost:4567

## Usage

Upload two images and compare.

Three algorithms:
- **SSIM**: Structural similarity (considers luminance, contrast, structure)
- **Delta E**: RGB color distance
- **Exact**: Pixel-by-pixel comparison

Changed pixels show as magenta.

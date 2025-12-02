# SSIM Playground

Web UI for comparing images using SSIM, Delta E, and pixel-level diff algorithms.

Take a look at the blog post I wrote explaining it all:

https://urlbox.com/detect-website-changes

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


Here's the raw Method in Ruby for SSIM I implemented if you just want something cheap and quick to copy:


```ruby
  LUMINANCE_STABILITY_FACTOR = 0.01
  CONTRAST_STABILITY_FACTOR = 0.03
  LUMINANCE_CONSTANT = (LUMINANCE_STABILITY_FACTOR * 255)**2
  CONTRAST_CONSTANT = (CONTRAST_STABILITY_FACTOR * 255)**2
  BLUR_RADIUS = 1.5
 
  def ssim_map(img1, img2)
	image1 = img1.bands > 1 ? img1.colourspace("b-w") : img1
	image2 = img2.bands > 1 ? img2.colourspace("b-w") : img2
 
	image1 = image1.cast("float")
	image2 = image2.cast("float")
 
	mean1 = image1.gaussblur(BLUR_RADIUS)
	mean2 = image2.gaussblur(BLUR_RADIUS)
 
	variance1 = (image1 * image1).gaussblur(BLUR_RADIUS) - (mean1 * mean1)
	variance2 = (image2 * image2).gaussblur(BLUR_RADIUS) - (mean2 * mean2)
	covariance = (image1 * image2).gaussblur(BLUR_RADIUS) - (mean1 * mean2)
 
    numerator = (mean1 * mean2 * 2 + LUMINANCE_CONSTANT) * (covariance * 2 + CONTRAST_CONSTANT)
    denominator = (mean1 * mean1 + mean2 * mean2 + LUMINANCE_CONSTANT) * (variance1 + variance2 + CONTRAST_CONSTANT)
 
    numerator / denominator
  end
```


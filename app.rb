require "sinatra"
require "vips"
require "base64"
require "json"

class SSIMPlayground < Sinatra::Base
  set :port, 4567
  set :views, Proc.new { File.join(root, "views") }
  set :public_folder, Proc.new { File.join(root, "public") }

  get "/" do
    erb :index
  end

  post "/compare" do
    # Get the uploaded images from the form
    img1_path = params[:img1][:tempfile].path
    img2_path = params[:img2][:tempfile].path

    # Get user settings
    threshold = params[:threshold].to_f  # How sensitive we are to differences (0.0-1.0)
    ignore_luminance = params[:ignore_luminance] == "true"  # Should we ignore brightness?

    # SSIM paper standard values (from the original research paper)
    blur_radius = 1.5        # How big of an area to look at when comparing (bigger = compare regions, not individual pixels)
    c1_factor = 0.01   # Stability constant for brightness calculations (prevents divide-by-zero in dark areas)
    c2_factor = 0.03   # Stability constant for contrast calculations (prevents divide-by-zero in flat areas)

    # Load the images
    img1 = Vips::Image.new_from_file(img1_path)
    img2 = Vips::Image.new_from_file(img2_path)

    # Make sure both images are the same size (resize if needed)
    if img1.width != img2.width || img1.height != img2.height
      img2 = img2.resize(img1.width.to_f / img2.width)
      if img2.height > img1.height
        img2 = img2.crop(0, 0, img1.width, img1.height)  # Cut off the bottom
      elsif img2.height < img1.height
        img2 = img2.gravity("north", img1.width, img1.height)  # Add padding at bottom
      end
    end

    # Make sure both images have the same color format
    # "bands" = color channels (1=grayscale, 3=RGB, 4=RGBA with transparency)
    if img1.bands != img2.bands
      # Convert grayscale to RGB if needed
      img1 = img1.colourspace("srgb") if img1.bands < 3
      img2 = img2.colourspace("srgb") if img2.bands < 3
      # Add transparency channel if one image has it and the other doesn't
      if img1.bands == 4 && img2.bands == 3
        img2 = img2.bandjoin(255)  # Add opaque alpha channel
      elsif img1.bands == 3 && img2.bands == 4
        img1 = img1.bandjoin(255)  # Add opaque alpha channel
      end
    end

    # === SSIM COMPARISON (Structure + Contrast, optionally ignoring brightness) ===
    ssim_map = compute_ssim_map(img1, img2, blur_radius, c1_factor, c2_factor, ignore_luminance)

    # Make sure the similarity map is grayscale (single channel)
    # It should already be, but we force it just to be safe
    ssim_map = ssim_map.extract_band(0) if ssim_map.bands > 1

    # Mark pixels as "changed" if their similarity score is below the threshold
    # Example: if threshold = 0.95, any pixel with score < 0.95 is marked as changed
    changed_pixels_ssim = ssim_map < threshold

    # Create a magenta color to highlight changed pixels
    # We need to match the color format of our original image
    magenta_values = case img1.bands
    when 1
      [255]  # White for grayscale
    when 2
      [255, 255]  # White + full opacity for grayscale with transparency
    when 3
      [255, 0, 255]  # Magenta for RGB (Red=255, Green=0, Blue=255)
    when 4
      [255, 0, 255, 255]  # Magenta + full opacity for RGBA
    else
      [255, 0, 255]  # Default to RGB magenta
    end
    magenta = img1.new_from_image(magenta_values)

    # Create the diff image: show magenta where pixels changed, original image where they didn't
    # This is like saying "if changed, show magenta, else show original"
    ssim_result = changed_pixels_ssim.ifthenelse(magenta, img1)

    # === DELTA E COMPARISON (RGB Color Distance) ===
    # This measures how far apart colors are in RGB space (like measuring distance on a color wheel)
    # Returns a value from 0.0 (identical colors) to 1.0 (maximum possible difference)
    delta_e_map = compute_delta_e_map(img1, img2)

    # Mark pixels as "changed" if their color distance is above the threshold
    # Note: Delta E is "distance" not "similarity", so we flip the threshold
    # SSIM: threshold 0.95 means "mark if similarity < 0.95" (less similar than 95%)
    # Delta E: threshold 0.95 means "mark if distance > 0.05" (more than 5% different)
    changed_pixels_delta_e = delta_e_map > (1.0 - threshold)

    # Create the Delta E diff image (same as SSIM: magenta where changed, original where not)
    delta_e_result = changed_pixels_delta_e.ifthenelse(magenta, img1)

    # === EXACT PIXEL COMPARISON (Atomic/Binary) ===
    # This is the strictest method: pixels are either identical or different, no in-between
    # Even a 1-bit difference in color values will be detected
    changed_pixels_exact = compute_pixel_diff_map(img1, img2)

    # Create the exact diff image
    exact_result = changed_pixels_exact.ifthenelse(magenta, img1)

    # Calculate statistics
    total_pixels = img1.width * img1.height

    # SSIM statistics
    changed_fraction_ssim = changed_pixels_ssim.cast("uchar").avg / 255.0
    changed_count_ssim = (changed_fraction_ssim * total_pixels).round(0)
    changed_percent_ssim = (changed_fraction_ssim * 100).round(2)

    ssim_min = ssim_map.min
    ssim_max = ssim_map.max
    ssim_avg = ssim_map.avg

    # Delta E statistics
    changed_fraction_delta_e = changed_pixels_delta_e.cast("uchar").avg / 255.0
    changed_count_delta_e = (changed_fraction_delta_e * total_pixels).round(0)
    changed_percent_delta_e = (changed_fraction_delta_e * 100).round(2)

    delta_e_min = delta_e_map.min
    delta_e_max = delta_e_map.max
    delta_e_avg = delta_e_map.avg

    # Exact diff statistics
    changed_fraction_exact = changed_pixels_exact.cast("uchar").avg / 255.0
    changed_count_exact = (changed_fraction_exact * total_pixels).round(0)
    changed_percent_exact = (changed_fraction_exact * 100).round(2)

    # Convert images to base64
    ssim_result_buffer = ssim_result.write_to_buffer(".png")
    ssim_result_base64 = Base64.strict_encode64(ssim_result_buffer)

    delta_e_result_buffer = delta_e_result.write_to_buffer(".png")
    delta_e_result_base64 = Base64.strict_encode64(delta_e_result_buffer)

    exact_result_buffer = exact_result.write_to_buffer(".png")
    exact_result_base64 = Base64.strict_encode64(exact_result_buffer)

    img1_buffer = img1.write_to_buffer(".png")
    img1_base64 = Base64.strict_encode64(img1_buffer)

    img2_buffer = img2.write_to_buffer(".png")
    img2_base64 = Base64.strict_encode64(img2_buffer)

    content_type :json
    {
      ssim_image: "data:image/png;base64,#{ssim_result_base64}",
      delta_e_image: "data:image/png;base64,#{delta_e_result_base64}",
      exact_image: "data:image/png;base64,#{exact_result_base64}",
      img1: "data:image/png;base64,#{img1_base64}",
      img2: "data:image/png;base64,#{img2_base64}",
      stats: {
        threshold: threshold,
        blur_radius: blur_radius,
        c1: (c1_factor * 255)**2,
        c2: (c2_factor * 255)**2,
        ssim_min: ssim_min.round(4),
        ssim_max: ssim_max.round(4),
        ssim_avg: ssim_avg.round(4),
        ssim_changed_pixels: changed_count_ssim.round(0),
        ssim_changed_percent: changed_percent_ssim,
        delta_e_min: delta_e_min.round(4),
        delta_e_max: delta_e_max.round(4),
        delta_e_avg: delta_e_avg.round(4),
        delta_e_changed_pixels: changed_count_delta_e.round(0),
        delta_e_changed_percent: changed_percent_delta_e,
        exact_changed_pixels: changed_count_exact.round(0),
        exact_changed_percent: changed_percent_exact,
        total_pixels: total_pixels,
        image_size: "#{img1.width}×#{img1.height}"
      }
    }.to_json
  end

  def compute_ssim_map(img1, img2, blur_radius, c1_factor, c2_factor, ignore_luminance = false)
    # ===== STEP 1: Convert to grayscale =====
    # SSIM works on brightness patterns, not colors
    # So we convert color images to grayscale (black & white)
    image1 = img1.bands > 1 ? img1.colourspace("b-w") : img1
    image2 = img2.bands > 1 ? img2.colourspace("b-w") : img2

    # Convert to floating point numbers for accurate math
    image1 = image1.cast("float")
    image2 = image2.cast("float")

    # ===== STEP 2: Calculate local averages (brightness) =====
    # "mean" = average brightness in a small local neighborhood around each pixel
    # We blur the image slightly to get the "local average" brightness
    mean1 = image1.gaussblur(blur_radius)
    mean2 = image2.gaussblur(blur_radius)

    # ===== STEP 3: Calculate variance (contrast) =====
    # Variance = how much pixels differ from their local average
    # High variance = lots of texture/detail, Low variance = flat/smooth
    variance1 = (image1 * image1).gaussblur(blur_radius) - (mean1 * mean1)  # Variance of img1
    variance2 = (image2 * image2).gaussblur(blur_radius) - (mean2 * mean2)  # Variance of img2

    # ===== STEP 4: Calculate covariance (structure) =====
    # Covariance = how much the two images vary together
    # High covariance = similar patterns/structure
    covariance = (image1 * image2).gaussblur(blur_radius) - (mean1 * mean2)

    # ===== STEP 5: Stability constants =====
    # These prevent division by zero in dark or flat areas
    c1 = (c1_factor * 255)**2  # For luminance comparison
    c2 = (c2_factor * 255)**2  # For contrast comparison

    # ===== STEP 6: Calculate SSIM =====
    if ignore_luminance
      # CS-SSIM Mode: Only compare structure and contrast (ignore brightness)
      # Perfect for detecting real changes while ignoring shadows/overlays
      numerator = (covariance * 2 + c2)
      denominator = (variance1 + variance2 + c2)
    else
      # Full SSIM: Compare brightness, contrast, AND structure
      # This is the complete formula from the research paper
      numerator = (mean1 * mean2 * 2 + c1) * (covariance * 2 + c2)
      denominator = (mean1 * mean1 + mean2 * mean2 + c1) * (variance1 + variance2 + c2)
    end

    # Return the similarity map (0.0 = totally different, 1.0 = identical)
    numerator / denominator
  end

  def compute_delta_e_map(img1, img2)
    # ===== Delta E: Measures "color distance" in RGB space =====
    # Think of it like measuring how far apart two points are on a 3D color cube
    # Red, Green, and Blue are the three dimensions

    # Make sure we're working with RGB color images (not grayscale)
    a = img1.bands == 1 ? img1.colourspace("srgb") : img1
    b = img2.bands == 1 ? img2.colourspace("srgb") : img2

    # Convert to floating point for accurate math
    a = a.cast("float")
    b = b.cast("float")

    # Calculate the difference in each color channel
    # For each pixel, we find: how different is the Red? Green? Blue?
    diff_r = (b[0] - a[0]) * (b[0] - a[0])  # Red difference, squared
    diff_g = (b[1] - a[1]) * (b[1] - a[1])  # Green difference, squared
    diff_b = (b[2] - a[2]) * (b[2] - a[2])  # Blue difference, squared

    # Add up all the differences and take the square root
    # This is the Pythagorean theorem in 3D: √(R² + G² + B²)
    sum_squared = diff_r + diff_g + diff_b
    euclidean = sum_squared ** 0.5

    # Normalize the distance to be between 0.0 and 1.0
    # Maximum possible distance is when going from black (0,0,0) to white (255,255,255)
    # That's √(255² + 255² + 255²) ≈ 441.67
    max_distance = Math.sqrt(255 * 255 * 3)
    euclidean / max_distance  # Returns 0.0 (identical) to 1.0 (max difference)
  end

  def compute_pixel_diff_map(img1, img2)
    # ===== Exact Pixel Comparison: The Strictest Method =====
    # This is a simple "are they EXACTLY the same?" check
    # Even if just 1 out of 255 brightness levels differs, it counts as different
    # Use this when you need to know if images are byte-for-byte identical

    # Make sure both images are in RGB format
    a = img1.bands == 1 ? img1.colourspace("srgb") : img1
    b = img2.bands == 1 ? img2.colourspace("srgb") : img2

    # Subtract the images and take absolute value
    # If a pixel is the same, difference = 0
    # If a pixel is different, difference > 0
    diff = (a - b).abs

    # Check if ANY color channel (R, G, or B) is different
    # If Red OR Green OR Blue differs, the pixel is marked as changed
    # Adding them together: if sum > 0, at least one channel differs
    (diff[0] + diff[1] + diff[2]) > 0
  end
end

# Run the app if executed directly
SSIMPlayground.run! if __FILE__ == $0

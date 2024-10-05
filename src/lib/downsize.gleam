import ansel
import ansel/image
import gleam/int
import snag

pub fn calculate_scale(image, target_size) {
  let original_width = image.get_width(image)
  let original_height = image.get_height(image)

  case original_width > original_height {
    True -> int.to_float(target_size) /. int.to_float(original_height)
    False -> int.to_float(target_size) /. int.to_float(original_width)
  }
}

pub fn image_by(
  image: ansel.Image,
  scale scale: Float,
) -> Result(ansel.Image, snag.Snag) {
  image.resize_by(image, scale)
  |> snag.context("Failed to downsize image")
}

pub fn image_to(
  image: ansel.Image,
  size target_size: Int,
) -> Result(ansel.Image, snag.Snag) {
  let original_width = image.get_width(image)
  let original_height = image.get_height(image)

  case original_width > original_height {
    True -> image.resize_height_to(image, target_size)
    False -> image.resize_width_to(image, target_size)
  }
  |> snag.context("Failed to downsize image")
}

pub fn restore_image(tiny_image: ansel.Image, to baseline: Int) {
  let baseline_width = image.get_width(tiny_image)
  let baseline_height = image.get_height(tiny_image)

  case baseline_width > baseline_height {
    True -> image.resize_height_to(tiny_image, baseline)
    False -> image.resize_width_to(tiny_image, baseline)
  }
}

pub fn video() {
  panic as "Not implemented yet"
}

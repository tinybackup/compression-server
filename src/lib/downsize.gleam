import ansel
import ansel/image
import gleam/int
import snag

pub fn calculate_scale(image, target_size) {
  let original_width = image.get_width(image)
  let original_height = image.get_height(image)

  case original_width > original_height {
    True -> int.to_float(target_size) /. int.to_float(original_width)
    False -> int.to_float(target_size) /. int.to_float(original_height)
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
    True -> image.resize_width_to(image, target_size)
    False -> image.resize_height_to(image, target_size)
  }
  |> snag.context("Failed to downsize image")
}

pub fn video() {
  panic as "Not implemented yet"
}

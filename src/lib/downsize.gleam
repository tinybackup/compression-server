import ansel
import ansel/image
import snag

pub fn image(
  image: ansel.Image,
  target_size: Int,
) -> Result(ansel.Image, snag.Snag) {
  let original_width = image.get_width(image)
  let original_height = image.get_height(image)

  case original_width > original_height {
    True -> image.resize_width_to(image, target_size)
    False -> image.resize_height_to(image, target_size)
  }
}

pub fn video() {
  panic as "Not implemented yet"
}

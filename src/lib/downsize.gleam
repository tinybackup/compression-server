import ansel
import snag

pub fn image(
  image: ansel.Image,
  target_size: Int,
) -> Result(ansel.Image, snag.Snag) {
  let original_width = ansel.get_width(image)
  let original_height = ansel.get_height(image)

  case original_width > original_height {
    True -> ansel.resize_width_to(image, target_size)
    False -> ansel.resize_height_to(image, target_size)
  }
}

pub fn video() {
  panic as "Not implemented yet"
}

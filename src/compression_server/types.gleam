import ansel
import ansel/fixed_bounding_box
import ansel/image

pub const bit_separator = "tbdv1"

pub type TargetSize {
  Original
  Medium
  CompatableMedium
  Small
  CompatableSmall
  Tiny
  CompatableTiny
}

pub type ImageConfig {
  ImageConfig(
    baseline_size: Int,
    target_size: Int,
    quality: Int,
    focus_percent: Float,
    write_face: fn(ansel.Image) -> BitArray,
    write_focus_point: fn(ansel.Image) -> BitArray,
    write_detail: fn(ansel.Image) -> BitArray,
    compatability_mode: Bool,
  )
}

pub fn get_image_config(
  target_size: TargetSize,
  is_favorite: Bool,
) -> ImageConfig {
  let target_size = case is_favorite {
    True -> size_up(target_size)
    False -> target_size
  }

  case target_size {
    Tiny ->
      ImageConfig(
        baseline_size: 1080,
        target_size: 600,
        quality: 30,
        focus_percent: 0.45,
        write_face: fn(image) {
          image.to_bit_array(image, ansel.AVIF(quality: 40))
        },
        write_focus_point: fn(image) {
          image.to_bit_array(image, ansel.AVIF(quality: 30))
        },
        write_detail: fn(image) {
          image.to_bit_array(image, ansel.AVIF(quality: 50))
        },
        compatability_mode: False,
      )

    CompatableTiny ->
      ImageConfig(
        baseline_size: 1080,
        target_size: 600,
        quality: 30,
        focus_percent: 0.45,
        write_face: fn(image) {
          image.to_bit_array(image, ansel.JPEG(quality: 40))
        },
        write_focus_point: fn(image) {
          image.to_bit_array(image, ansel.JPEG(quality: 30))
        },
        write_detail: fn(image) {
          image.to_bit_array(image, ansel.JPEG(quality: 50))
        },
        compatability_mode: True,
      )

    _ -> panic as "Config not implemented"
  }
}

fn size_up(target_size: TargetSize) -> TargetSize {
  case target_size {
    Original -> Original
    Medium -> Original
    CompatableMedium -> Original
    Small -> Medium
    CompatableSmall -> CompatableMedium
    Tiny -> Small
    CompatableTiny -> CompatableSmall
  }
}

pub type CompressionRequest {
  Image(
    image: ansel.Image,
    date: String,
    is_favorite: Bool,
    target_size: TargetSize,
    original_file_path: String,
    user_metadata: String,
    faces: List(fixed_bounding_box.FixedBoundingBox),
  )
  Video
}

pub type ExtractedArea {
  ExtractedArea(
    area: ansel.Image,
    bounding_box: fixed_bounding_box.FixedBoundingBox,
  )
}

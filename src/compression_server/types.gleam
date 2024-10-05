import ansel
import ansel/fixed_bounding_box
import ansel/image
import gleam/option
import tempo

pub const bit_separator = <<"tbdv01">>

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
    write_baseline: fn(ansel.Image) -> BitArray,
    write_face: fn(ansel.Image) -> BitArray,
    focus_percent: Float,
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
        baseline_size: 810,
        target_size: 450,
        write_baseline: fn(image) {
          image.to_bit_array(
            image,
            ansel.Custom(".avif[Q=30,strip=true,effort=4]"),
          )
        },
        write_face: fn(image) {
          image.to_bit_array(
            image,
            ansel.Custom(".avif[Q=40,strip=true,effort=4]"),
          )
        },
        focus_percent: 0.45,
        write_focus_point: fn(image) {
          image.to_bit_array(
            image,
            ansel.Custom(".avif[Q=30,strip=true,effort=4]"),
          )
        },
        write_detail: fn(image) {
          image.to_bit_array(
            image,
            ansel.Custom(".avif[Q=50,strip=true,effort=4]"),
          )
        },
        compatability_mode: False,
      )

    CompatableTiny ->
      ImageConfig(
        baseline_size: 810,
        target_size: 450,
        write_baseline: fn(image) {
          image.to_bit_array(
            image,
            ansel.JPEG(quality: 30, keep_metadata: False),
          )
        },
        write_face: fn(image) {
          image.to_bit_array(
            image,
            ansel.JPEG(quality: 40, keep_metadata: False),
          )
        },
        focus_percent: 0.45,
        write_focus_point: fn(image) {
          image.to_bit_array(
            image,
            ansel.JPEG(quality: 30, keep_metadata: False),
          )
        },
        write_detail: fn(image) {
          image.to_bit_array(
            image,
            ansel.JPEG(quality: 50, keep_metadata: False),
          )
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
    datetime: tempo.NaiveDateTime, // Make sure this has second precision
    datetime_offset: option.Option(tempo.Offset),
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

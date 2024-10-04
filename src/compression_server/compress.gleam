import ansel
import ansel/fixed_bounding_box
import compression_server/types as core_types
import gleam/list
import gleam/result
import lib/downsize
import lib/embed
import lib/extract_detail
import lib/extract_faces
import lib/extract_focus
import lib/form_metadata
import snag

pub fn image(
  image: ansel.Image,
  date: String,
  config: core_types.ImageConfig,
  original_file_path: String,
  is_favorite: Bool,
  user_metadata: String,
  faces: List(fixed_bounding_box.FixedBoundingBox),
) {
  {
    let baseline_scale = downsize.calculate_scale(image, config.baseline_size)

    use baseline_image <- result.try(downsize.image_by(
      image,
      scale: baseline_scale,
    ))

    let faces =
      list.map(faces, fixed_bounding_box.resize_by(_, scale: baseline_scale))

    use face_areas <- result.try(extract_faces.from_image(baseline_image, faces))

    use focus_point_areas <- result.try(extract_focus.from_image(
      baseline_image,
      config.focus_percent,
    ))

    use detail_areas <- result.try(extract_detail.from_image(baseline_image))

    let metadata =
      form_metadata.for_image(
        config.baseline_size,
        face_areas |> list.map(fn(area) { area.bounding_box }),
        focus_point_areas |> list.map(fn(area) { area.bounding_box }),
        date,
        original_file_path,
        is_favorite,
        user_metadata,
      )

    use tiny_image <- result.map(downsize.image_to(
      baseline_image,
      size: config.target_size,
    ))

    embed.into_image(
      tiny_image,
      face_areas,
      focus_point_areas,
      detail_areas,
      metadata,
      config,
    )
  }
  |> snag.context("Failed to compress image")
}

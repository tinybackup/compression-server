import ansel
import ansel/fixed_bounding_box
import compression_server/lib/downsize
import compression_server/lib/embed
import compression_server/lib/extract_detail
import compression_server/lib/extract_faces
import compression_server/lib/extract_focus
import compression_server/lib/form_metadata
import compression_server/types as core_types
import gleam/list
import gleam/option
import gleam/result
import snag
import tempo

pub fn image(
  image image: ansel.Image,
  naive_datetime naive_datetime: tempo.NaiveDateTime,
  offset offset: option.Option(tempo.Offset),
  config config: core_types.ImageConfig,
  original_file_path original_file_path: String,
  is_favorite is_favorite: Bool,
  user_metadata user_metadata: String,
  faces faces: List(fixed_bounding_box.FixedBoundingBox),
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

    let metadata_chunk =
      form_metadata.for_image(
        config.baseline_size,
        face_areas |> list.map(fn(area) { area.bounding_box }),
        focus_point_areas |> list.map(fn(area) { area.bounding_box }),
        detail_areas |> list.map(fn(area) { area.bounding_box }),
        naive_datetime,
        offset,
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
      metadata_chunk,
      config,
    )
  }
  |> snag.context("Failed to compress image")
}

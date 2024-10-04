import ansel
import ansel/color
import ansel/fixed_bounding_box
import ansel/image
import compression_server/types as core_types
import gleam/bit_array
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/option
import lib/form_metadata

pub fn into_image(
  tiny_image: ansel.Image,
  faces: List(core_types.ExtractedArea),
  focus_points: List(core_types.ExtractedArea),
  details: List(core_types.ExtractedArea),
  metadata,
  config: core_types.ImageConfig,
) {
  let tiny_scale =
    int.to_float(config.target_size) /. int.to_float(config.baseline_size)

  let focus_point_bounding_boxes =
    list.map(focus_points, fn(area) { area.bounding_box })

  let face_bounding_boxes = list.map(faces, fn(area) { area.bounding_box })

  let detail_bounding_boxes = list.map(details, fn(area) { area.bounding_box })

  // When compatability mode is not enabled, write grey pixels in parts
  // of the baseline and focus point images that were extracted in 
  // higher quality in other areas. This reduces the output file size.
  let #(baseline, focus_points) = case config.compatability_mode {
    True -> #(tiny_image, focus_points)

    False -> #(
      tiny_image
        |> backfill_extracted_areas(face_bounding_boxes, tiny_scale)
        |> backfill_extracted_areas(focus_point_bounding_boxes, tiny_scale)
        |> backfill_extracted_areas(detail_bounding_boxes, tiny_scale),
      focus_points
        |> list.map(fn(extracted_area) {
          core_types.ExtractedArea(
            ..extracted_area,
            area: backfill_extracted_areas(
              extracted_area.area,
              face_bounding_boxes,
              tiny_scale,
            ),
          )
        }),
    )
  }

  let baseline = config.write_baseline(baseline)

  let faces =
    list.map(faces, fn(extracted_area) {
      config.write_face(extracted_area.area)
    })

  let focus_points =
    list.map(focus_points, fn(extracted_area) {
      config.write_focus_point(extracted_area.area)
    })

  let details =
    list.map(details, fn(extracted_area) {
      config.write_detail(extracted_area.area)
    })

  let baseline_length = bit_array.byte_size(baseline)
  let faces_length = list.map(faces, bit_array.byte_size)
  let focus_points_length = list.map(focus_points, bit_array.byte_size)
  let details_length = list.map(details, bit_array.byte_size)
  let metadata_length = bytes_builder.byte_size(metadata)

  let file_footer =
    form_metadata.for_image_footer(
      baseline_length,
      metadata_length,
      faces_length,
      focus_points_length,
      details_length,
    )

  bytes_builder.from_bit_array(baseline)
  // If metadata is second after the baseline instead of another image,
  // more image viewers will be able to read it.
  |> bytes_builder.append_builder(metadata)
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(faces))
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(focus_points))
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(details))
  |> bytes_builder.append_builder(file_footer)
  |> bytes_builder.to_bit_array
}

fn backfill_extracted_areas(tiny_image, areas, tiny_image_scale) {
  let width = image.get_width(tiny_image)
  let height = image.get_height(tiny_image)

  case fixed_bounding_box.ltwh(0, 0, width, height) {
    Ok(base) ->
      areas
      |> list.map(fixed_bounding_box.resize_by(_, scale: tiny_image_scale))
      |> list.map(fixed_bounding_box.intersection(base, _))
      |> option.values
      |> list.map(fixed_bounding_box.shrink(_, by: 5))
      |> option.values
      |> list.fold(from: tiny_image, with: fn(image, area) {
        case image.fill(image, in: area, with: color.Grey) {
          Ok(filled) -> filled
          Error(_) -> image
        }
      })
    Error(_) -> tiny_image
  }
}

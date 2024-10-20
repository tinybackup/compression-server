import ansel
import ansel/bounding_box
import ansel/color
import ansel/image
import compression_server/lib/form_metadata
import compression_server/types as core_types
import gleam/bit_array
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string

pub fn into_image(
  tiny_image: ansel.Image,
  faces: List(core_types.ExtractedArea),
  focus_points: List(core_types.ExtractedArea),
  details: List(core_types.ExtractedArea),
  metadata_chunk: bytes_builder.BytesBuilder,
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
        |> backfill_tiny_image(face_bounding_boxes, tiny_scale)
        |> backfill_tiny_image(focus_point_bounding_boxes, tiny_scale)
        |> backfill_tiny_image(detail_bounding_boxes, tiny_scale),
      focus_points
        |> list.map(fn(extracted_area) {
          core_types.ExtractedArea(
            ..extracted_area,
            area: backfill_extracted_areas(extracted_area, face_bounding_boxes),
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
  let metadata_length = bytes_builder.byte_size(metadata_chunk)

  let file_footer_chunk =
    form_metadata.for_image_footer(
      baseline_length,
      metadata_length,
      faces_length,
      focus_points_length,
      details_length,
    )

  let footer_size_chunk =
    bit_array.concat([
      core_types.bit_separator,
      file_footer_chunk
        |> bytes_builder.byte_size
        |> int.to_string
        |> string.pad_left(to: form_metadata.footer_size_marker_size, with: "0")
        |> bit_array.from_string,
    ])

  bytes_builder.from_bit_array(baseline)
  // If metadata is second after the baseline instead of another image,
  // more image viewers will be able to read it.
  |> bytes_builder.append_builder(metadata_chunk)
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(faces))
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(focus_points))
  |> bytes_builder.append_builder(bytes_builder.concat_bit_arrays(details))
  |> bytes_builder.append_builder(file_footer_chunk)
  |> bytes_builder.append(footer_size_chunk)
  |> bytes_builder.to_bit_array
}

fn backfill_tiny_image(tiny_image, areas, tiny_image_scale) {
  let width = image.get_width(tiny_image)
  let height = image.get_height(tiny_image)

  case bounding_box.ltwh(0, 0, width, height) {
    Ok(base) ->
      areas
      |> list.map(bounding_box.scale(_, by: tiny_image_scale))
      |> list.map(bounding_box.shrink(_, by: 5))
      |> result.values
      |> list.map(bounding_box.intersection(base, _))
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

fn backfill_extracted_areas(
  extracted_area: core_types.ExtractedArea,
  greater_extracted_bb,
) {
  let extracted_bb = extracted_area.bounding_box

  greater_extracted_bb
  |> list.map(bounding_box.shrink(_, by: 5))
  |> result.values
  |> list.map(bounding_box.intersection(extracted_bb, _))
  |> option.values
  |> list.map(bounding_box.make_relative(_, to: extracted_bb))
  |> option.values
  |> list.fold(from: extracted_area.area, with: fn(extracted_image, int) {
    // If the area to fill takes up a total part of the image so that there
    // is only one square of non-grey pixels, then the grey part to fill
    // could be cut out of the image to save some space. Maybe about 200 bytes
    // when applicable. But then we have to go back and update the metadata.
    case image.fill(extracted_image, in: int, with: color.Grey) {
      Ok(filled) -> filled
      Error(_) -> extracted_image
    }
  })
}

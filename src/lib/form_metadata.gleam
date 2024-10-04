import ansel/fixed_bounding_box
import compression_server/types as core_types
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import tempo
import tempo/naive_datetime
import tempo/offset

const baseline_marker = "b"

const time_marker = "t"

const offset_marker = "z"

const file_path_marker = "a"

const favorite_marker = "v"

const user_metadata_marker = "u"

const metadata_marker = "m"

const face_marker = "f"

const focus_point_marker = "p"

const detail_marker = "d"

pub fn for_image(
  baseline_size: Int,
  face_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  focus_point_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  detail_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  datetime: tempo.NaiveDateTime,
  datetime_offset: option.Option(tempo.Offset),
  original_file_path: String,
  is_favorite: Bool,
  user_metadata: String,
) {
  bytes_builder.from_string(core_types.bit_separator)
  |> bytes_builder.append_string(baseline_marker)
  |> bytes_builder.append_string(baseline_size |> int.to_string)
  |> bytes_builder.append_string(time_marker)
  |> bytes_builder.append_string(datetime |> naive_datetime.to_string)
  |> bytes_builder.append_string(offset_marker)
  |> bytes_builder.append_string(case datetime_offset {
    Some(offset) -> offset |> offset.to_string
    None -> ":"
  })
  |> bytes_builder.append_string(file_path_marker)
  |> bytes_builder.append_string("\"")
  |> bytes_builder.append_string(
    original_file_path |> string.replace("\"", "'"),
  )
  |> bytes_builder.append_string("\"")
  |> bytes_builder.append_string(favorite_marker)
  |> bytes_builder.append_string(case is_favorite {
    True -> "1"
    False -> "0"
  })
  |> bytes_builder.append_string(user_metadata_marker)
  |> bytes_builder.append_string("\"")
  |> bytes_builder.append_string(user_metadata |> string.replace("\"", "'"))
  |> bytes_builder.append_string("\"")
  |> bytes_builder.append_builder(
    list.map(face_bounding_boxes, fn(bounding_box) {
      let #(x, y, w, h) = fixed_bounding_box.to_ltwh_tuple(bounding_box)

      bytes_builder.from_string(face_marker)
      |> bytes_builder.append_string(x |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(y |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(w |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(h |> int.to_string)
    })
    |> bytes_builder.concat,
  )
  |> bytes_builder.append_builder(
    list.map(focus_point_bounding_boxes, fn(bounding_box) {
      let #(x, y, w, h) = fixed_bounding_box.to_ltwh_tuple(bounding_box)

      bytes_builder.from_string(focus_point_marker)
      |> bytes_builder.append_string(x |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(y |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(w |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(h |> int.to_string)
    })
    |> bytes_builder.concat,
  )
  |> bytes_builder.append_builder(
    list.map(detail_bounding_boxes, fn(bounding_box) {
      let #(x, y, w, h) = fixed_bounding_box.to_ltwh_tuple(bounding_box)

      bytes_builder.from_string(detail_marker)
      |> bytes_builder.append_string(x |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(y |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(w |> int.to_string)
      |> bytes_builder.append_string(",")
      |> bytes_builder.append_string(h |> int.to_string)
    })
    |> bytes_builder.concat,
  )
}

pub fn for_image_footer(
  baseline_length: Int,
  metadata_length: Int,
  faces_length: List(Int),
  focus_points_length: List(Int),
  details_length: List(Int),
) {
  bytes_builder.from_string(core_types.bit_separator)
  |> bytes_builder.append_string(baseline_marker)
  |> bytes_builder.append_string(metadata_length |> int.to_string)
  |> bytes_builder.append_string(metadata_marker)
  |> bytes_builder.append_string(baseline_length |> int.to_string)
  |> bytes_builder.append_builder(
    list.map(faces_length, fn(length) {
      bytes_builder.from_string(face_marker)
      |> bytes_builder.append_string(length |> int.to_string)
    })
    |> bytes_builder.concat,
  )
  |> bytes_builder.append_builder(
    list.map(focus_points_length, fn(length) {
      bytes_builder.from_string(focus_point_marker)
      |> bytes_builder.append_string(length |> int.to_string)
    })
    |> bytes_builder.concat,
  )
  |> bytes_builder.append_builder(
    list.map(details_length, fn(length) {
      bytes_builder.from_string(detail_marker)
      |> bytes_builder.append_string(length |> int.to_string)
    })
    |> bytes_builder.concat,
  )
}

pub fn read_image_footer(from_image bits: BitArray) {
  todo
}

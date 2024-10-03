import ansel/fixed_bounding_box
import compression_server/types as core_types
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/string

pub fn for_image(
  baseline_size: Int,
  face_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  focus_point_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  date: String,
  original_file_path: String,
  is_favorite: Bool,
  user_metadata: String,
) {
  bytes_builder.from_string(core_types.bit_separator)
  |> bytes_builder.append_string("b")
  |> bytes_builder.append_string(baseline_size |> int.to_string)
  |> bytes_builder.append_string("d")
  |> bytes_builder.append_string(date)
  |> bytes_builder.append_string("a\"")
  |> bytes_builder.append_string(
    original_file_path |> string.replace("\"", "'"),
  )
  |> bytes_builder.append_string("\"")
  |> bytes_builder.append_string(case is_favorite {
    True -> "1"
    False -> "0"
  })
  |> bytes_builder.append_builder(
    list.map(face_bounding_boxes, fn(bounding_box) {
      let #(x, y, w, h) = fixed_bounding_box.to_ltwh_tuple(bounding_box)

      bytes_builder.from_string("f")
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

      bytes_builder.from_string("p")
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
  |> bytes_builder.append_string(user_metadata)
  |> bytes_builder.to_bit_array
}

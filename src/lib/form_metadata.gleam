import ansel/fixed_bounding_box
import gleam/bytes_builder
import gleam/int
import gleam/list

pub fn for_image(
  baseline_size: Int,
  face_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  focus_point_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
  user_metadata: String,
) {
  bytes_builder.from_string("tbdv1")
  |> bytes_builder.append_string("b")
  |> bytes_builder.append_string(baseline_size |> int.to_string)
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
}

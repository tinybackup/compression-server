import ansel/fixed_bounding_box
import compression_server/types as core_types
import gleam/bit_array
import gleam/bool
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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

pub const footer_size_marker_size = 5

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
  |> bytes_builder.append_string(baseline_length |> int.to_string)
  |> bytes_builder.append_string(metadata_marker)
  |> bytes_builder.append_string(metadata_length |> int.to_string)
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

pub type ImageFooter {
  ImageFooter(
    baseline_length: Int,
    metadata_length: Int,
    face_lengths: List(Int),
    focus_point_lengths: List(Int),
    detail_lengths: List(Int),
  )
}

/// Reads a footer strictly in the format 
/// "tbdv01b6680m200f3286f3458f1396p3565p703p1375d492d735d787d626tbdv0100060"
/// where the last 5 bits are the footer length and the footer contains the
/// lengths of all other areas in the image.
pub fn read_image_footer(from_image bits: BitArray) {
  let bit_separator_size = core_types.bit_separator |> string.length

  let footer_size_marker_chunk_size =
    footer_size_marker_size + bit_separator_size

  use footer_size_marker <- result.try(bit_array.slice(
    from: bits,
    at: bit_array.byte_size(bits),
    take: -footer_size_marker_chunk_size,
  ))

  use bit_separator <- result.try(bit_array.slice(
    footer_size_marker,
    at: 0,
    take: bit_separator_size,
  ))

  use <- bool.guard(
    when: bit_separator != core_types.bit_separator |> bit_array.from_string,
    return: Error(Nil),
  )

  use footer_size <- result.try(
    bit_array.slice(
      footer_size_marker,
      at: bit_separator_size,
      take: footer_size_marker_size,
    )
    |> result.try(bit_array.to_string)
    |> result.try(int.parse),
  )

  use footer_chunk <- result.try(bit_array.slice(
    from: bits,
    at: bit_array.byte_size(bits) - footer_size_marker_chunk_size,
    take: -{ footer_size },
  ))

  use bit_separator <- result.try(bit_array.slice(
    footer_chunk,
    at: 0,
    take: bit_separator_size,
  ))

  use <- bool.guard(
    when: bit_separator != core_types.bit_separator |> bit_array.from_string,
    return: Error(Nil),
  )

  use footer_graphemes <- result.try(
    bit_array.slice(
      footer_chunk,
      at: core_types.bit_separator |> string.length,
      take: bit_array.byte_size(footer_chunk) - bit_separator_size,
    )
    |> result.try(bit_array.to_string)
    |> result.map(string.to_graphemes),
  )

  use #(baseline_length, unconsumed_graphemes) <- result.try(
    consume_single_value(footer_graphemes, baseline_marker),
  )

  use #(metadata_length, unconsumed_graphemes) <- result.try(
    consume_single_value(unconsumed_graphemes, metadata_marker),
  )

  use #(face_lengths, unconsumed_graphemes) <- result.try(
    consume_variable_values(unconsumed_graphemes, face_marker),
  )

  use #(focus_point_lengths, unconsumed_graphemes) <- result.try(
    consume_variable_values(unconsumed_graphemes, focus_point_marker),
  )

  use #(detail_lengths, unconsumed_graphemes) <- result.try(
    consume_variable_values(unconsumed_graphemes, detail_marker),
  )

  use <- bool.guard(when: unconsumed_graphemes != [], return: Error(Nil))

  Ok(ImageFooter(
    baseline_length:,
    metadata_length:,
    face_lengths:,
    focus_point_lengths:,
    detail_lengths:,
  ))
}

fn consume_single_value(graphemes, variable_marker) {
  use vars <- result.map(case graphemes {
    [v, ..rest] if v == variable_marker ->
      list.take_while(rest, fn(grapheme) {
        case int.parse(grapheme) {
          Ok(_) -> True
          Error(_) -> False
        }
      })
      |> string.join("")
      |> int.parse

    _ -> Error(Nil)
  })

  let unconsumed_graphemes =
    list.drop(graphemes, 1 + string.length(vars |> int.to_string))

  #(vars, unconsumed_graphemes)
}

fn consume_variable_values(graphemes, variable_marker) {
  use vars <- result.map(
    graphemes
    |> list.take_while(fn(grapheme) {
      case int.parse(grapheme), grapheme == variable_marker {
        Ok(_), _ -> True
        _, True -> True
        _, _ -> False
      }
    })
    |> string.join("")
    |> string.split(variable_marker)
    |> list.drop(1)
    |> list.map(int.parse)
    |> result.all,
  )

  let unconsumed_graphemes =
    list.drop(
      graphemes,
      list.length(vars)
        + list.fold(over: vars, from: 0, with: fn(acc, size) {
        acc + string.length(size |> int.to_string)
      }),
    )

  #(vars, unconsumed_graphemes)
}

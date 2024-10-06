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
import snag
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
  bytes_builder.from_bit_array(core_types.bit_separator)
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

pub type ImageMetadata {
  ImageMetadata(
    baseline_size: Int,
    face_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
    focus_point_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
    detail_bounding_boxes: List(fixed_bounding_box.FixedBoundingBox),
    datetime: tempo.NaiveDateTime,
    datetime_offset: option.Option(tempo.Offset),
    original_file_path: String,
    is_favorite: Bool,
    user_metadata: String,
  )
}

pub fn parse_image_metadata(image_metadata_chunk: BitArray) {
  use bit_separator <- result.try(
    bit_array.slice(
      from: image_metadata_chunk,
      at: 0,
      take: core_types.bit_separator |> bit_array.byte_size,
    )
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to split bit separator from image metadata chunk: "
        <> string.inspect(image_metadata_chunk),
      )
    }),
  )

  use <- bool.lazy_guard(
    when: bit_separator != core_types.bit_separator,
    return: fn() {
      snag.error(
        "Found invalid bit separator: " <> string.inspect(bit_separator),
      )
    },
  )

  use metadata_graphemes <- result.try(
    bit_array.slice(
      from: image_metadata_chunk,
      at: core_types.bit_separator |> bit_array.byte_size,
      take: bit_array.byte_size(image_metadata_chunk)
        - { core_types.bit_separator |> bit_array.byte_size },
    )
    |> result.try(bit_array.to_string)
    |> result.map(string.to_graphemes)
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to slice image metadata graphemes from: "
        <> string.inspect(image_metadata_chunk),
      )
    }),
  )

  use #(baseline_size, unconsumed_graphemes) <- result.try(consume_single_value(
    metadata_graphemes,
    baseline_marker,
    checker: int.parse,
    parser: int.parse,
  ))

  use #(datetime, unconsumed_graphemes) <- result.try(
    consume_single_value(
      unconsumed_graphemes,
      time_marker,
      checker: fn(grapheme) {
        int.parse(grapheme)
        |> result.try_recover(fn(_) {
          case grapheme == "-" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == "T" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == ":" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == "." {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
      },
      parser: fn(nd) { naive_datetime.from_string(nd) |> result.nil_error },
    ),
  )

  use #(datetime_offset, unconsumed_graphemes) <- result.try(
    consume_single_value(
      unconsumed_graphemes,
      offset_marker,
      checker: fn(grapheme) {
        int.parse(grapheme)
        |> result.try_recover(fn(_) {
          case grapheme == "Z" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == "z" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == ":" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == "-" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
        |> result.try_recover(fn(_) {
          case grapheme == "+" {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
      },
      parser: fn(nd) {
        case nd == ":" {
          True -> Ok(None)
          False ->
            case offset.from_string(nd) {
              Ok(offset) -> Ok(Some(offset))
              Error(_) -> Error(Nil)
            }
        }
      },
    ),
  )

  use #(original_file_path, unconsumed_graphemes) <- result.try(
    consume_sanitized_string(unconsumed_graphemes, file_path_marker),
  )

  use #(is_favorite, unconsumed_graphemes) <- result.try(
    consume_single_value(
      unconsumed_graphemes,
      favorite_marker,
      checker: int.parse,
      parser: fn(b) {
        case int.parse(b) {
          Ok(1) -> Ok(True)
          Ok(0) -> Ok(False)
          Ok(_) -> Error(Nil)
          Error(_) -> Error(Nil)
        }
      },
    ),
  )

  use #(user_metadata, unconsumed_graphemes) <- result.try(
    consume_sanitized_string(unconsumed_graphemes, user_metadata_marker),
  )

  use #(face_bounding_boxes, unconsumed_graphemes) <- result.try(
    consume_list_values(
      unconsumed_graphemes,
      face_marker,
      checker: fn(g) {
        int.parse(g)
        |> result.try_recover(fn(_) {
          case g == "," {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
      },
      parser: bounding_box_parser,
    ),
  )

  use #(focus_point_bounding_boxes, unconsumed_graphemes) <- result.try(
    consume_list_values(
      unconsumed_graphemes,
      focus_point_marker,
      checker: fn(g) {
        int.parse(g)
        |> result.try_recover(fn(_) {
          case g == "," {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
      },
      parser: bounding_box_parser,
    ),
  )

  use #(detail_bounding_boxes, unconsumed_graphemes) <- result.try(
    consume_list_values(
      unconsumed_graphemes,
      detail_marker,
      checker: fn(g) {
        int.parse(g)
        |> result.try_recover(fn(_) {
          case g == "," {
            True -> Ok(0)
            False -> Error(Nil)
          }
        })
      },
      parser: bounding_box_parser,
    ),
  )

  use <- bool.lazy_guard(when: unconsumed_graphemes != [], return: fn() {
    snag.error(
      "Found unconsumed graphemes left after parsing image metadata: "
      <> string.inspect(unconsumed_graphemes),
    )
  })

  Ok(ImageMetadata(
    baseline_size:,
    face_bounding_boxes:,
    focus_point_bounding_boxes:,
    detail_bounding_boxes:,
    datetime:,
    datetime_offset:,
    original_file_path:,
    is_favorite:,
    user_metadata:,
  ))
}

fn bounding_box_parser(bb_str) {
  case bb_str |> string.split(",") |> list.map(int.parse) |> result.all {
    Ok([x, y, w, h]) -> fixed_bounding_box.ltwh(x, y, w, h) |> result.nil_error
    Ok(_) -> Error(Nil)
    Error(_) -> Error(Nil)
  }
}

pub fn for_image_footer(
  baseline_length: Int,
  metadata_length: Int,
  faces_length: List(Int),
  focus_points_length: List(Int),
  details_length: List(Int),
) {
  bytes_builder.from_bit_array(core_types.bit_separator)
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
pub fn parse_image_footer(from_image bits: BitArray) {
  let bit_separator_size = core_types.bit_separator |> bit_array.byte_size

  let footer_size_marker_chunk_size =
    footer_size_marker_size + bit_separator_size

  use footer_size_marker <- result.try(
    bit_array.slice(
      from: bits,
      at: bit_array.byte_size(bits),
      take: -footer_size_marker_chunk_size,
    )
    |> result.replace_error(snag.new("Unable to slice image footer size chunk")),
  )

  use bit_separator <- result.try(
    bit_array.slice(footer_size_marker, at: 0, take: bit_separator_size)
    |> result.replace_error(snag.new(
      "Unable to split bit separator from footer size chunk",
    )),
  )

  use <- bool.lazy_guard(
    when: bit_separator != core_types.bit_separator,
    return: fn() {
      snag.error(
        "Found invalid footer size chunk bit separator: "
        <> string.inspect(bit_separator),
      )
    },
  )

  use footer_size <- result.try(
    bit_array.slice(
      footer_size_marker,
      at: bit_separator_size,
      take: footer_size_marker_size,
    )
    |> result.try(bit_array.to_string)
    |> result.try(int.parse)
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to parse footer size from: "
        <> string.inspect(footer_size_marker),
      )
    }),
  )

  use footer_chunk <- result.try(
    bit_array.slice(
      from: bits,
      at: bit_array.byte_size(bits) - footer_size_marker_chunk_size,
      take: -{ footer_size },
    )
    |> result.replace_error(snag.new("Unable to slice image footer chunk")),
  )

  use bit_separator <- result.try(
    bit_array.slice(footer_chunk, at: 0, take: bit_separator_size)
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to split bit separator from footer chunk: "
        <> string.inspect(footer_chunk),
      )
    }),
  )

  use <- bool.lazy_guard(
    when: bit_separator != core_types.bit_separator,
    return: fn() {
      snag.error(
        "Found invalid footer chunk bit separator: "
        <> string.inspect(bit_separator),
      )
    },
  )

  use footer_graphemes <- result.try(
    bit_array.slice(
      footer_chunk,
      at: bit_separator_size,
      take: bit_array.byte_size(footer_chunk) - bit_separator_size,
    )
    |> result.try(bit_array.to_string)
    |> result.map(string.to_graphemes)
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to slice footer graphemes from: "
        <> string.inspect(footer_chunk),
      )
    }),
  )

  use #(baseline_length, unconsumed_graphemes) <- result.try(
    consume_single_value(
      footer_graphemes,
      baseline_marker,
      checker: int.parse,
      parser: int.parse,
    ),
  )

  use #(metadata_length, unconsumed_graphemes) <- result.try(
    consume_single_value(
      unconsumed_graphemes,
      metadata_marker,
      checker: int.parse,
      parser: int.parse,
    ),
  )

  use #(face_lengths, unconsumed_graphemes) <- result.try(consume_list_values(
    unconsumed_graphemes,
    face_marker,
    checker: int.parse,
    parser: int.parse,
  ))

  use #(focus_point_lengths, unconsumed_graphemes) <- result.try(
    consume_list_values(
      unconsumed_graphemes,
      focus_point_marker,
      checker: int.parse,
      parser: int.parse,
    ),
  )

  use #(detail_lengths, unconsumed_graphemes) <- result.try(consume_list_values(
    unconsumed_graphemes,
    detail_marker,
    checker: int.parse,
    parser: int.parse,
  ))

  use <- bool.lazy_guard(when: unconsumed_graphemes != [], return: fn() {
    snag.error(
      "Found unconsumed graphemes left after parsing footer: "
      <> string.inspect(unconsumed_graphemes),
    )
  })

  Ok(ImageFooter(
    baseline_length:,
    metadata_length:,
    face_lengths:,
    focus_point_lengths:,
    detail_lengths:,
  ))
}

fn consume_single_value(
  graphemes,
  variable_marker,
  checker checker,
  parser parser,
) {
  use vars <- result.try(case graphemes {
    [v, ..rest] if v == variable_marker ->
      list.take_while(rest, fn(grapheme) {
        case checker(grapheme) {
          Ok(_) -> True
          Error(_) -> False
        }
      })
      |> string.join("")
      |> Ok

    _ ->
      fn() {
        snag.error(
          "Unable to consume single value with marker \""
          <> variable_marker
          <> "\" from "
          <> string.inspect(graphemes),
        )
      }()
  })

  let unconsumed_graphemes = list.drop(graphemes, 1 + string.length(vars))

  use vars <- result.map(
    parser(vars)
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to parse single value with marker \""
        <> variable_marker
        <> "\" from "
        <> vars,
      )
    }),
  )

  #(vars, unconsumed_graphemes)
}

fn consume_list_values(
  graphemes,
  variable_marker,
  checker checker,
  parser parser,
) {
  let vars =
    graphemes
    |> list.take_while(fn(grapheme) {
      case checker(grapheme), grapheme == variable_marker {
        Ok(_), _ -> True
        _, True -> True
        _, _ -> False
      }
    })
    |> string.join("")
    |> string.split(variable_marker)
    |> list.drop(1)

  let unconsumed_graphemes =
    list.drop(
      graphemes,
      list.length(vars)
        + list.fold(over: vars, from: 0, with: fn(acc, size) {
        acc + string.length(size)
      }),
    )

  use vars <- result.map(
    list.map(vars, parser)
    |> result.all
    |> result.map_error(fn(_) {
      snag.new(
        "Unable to parse list values with marker \""
        <> variable_marker
        <> "\" from "
        <> string.inspect(vars),
      )
    }),
  )

  #(vars, unconsumed_graphemes)
}

fn consume_sanitized_string(graphemes, variable_marker) {
  use vars <- result.map(case graphemes {
    [v, e, ..rest] if v == variable_marker && e == "\"" ->
      list.take_while(rest, fn(grapheme) { grapheme != "\"" })
      // An empty string is permitted
      |> fn(found) {
        case found == [] {
          True -> [""]
          False -> found
        }
      }
      |> string.join("")
      |> Ok

    _ ->
      fn() {
        snag.error(
          "Unable to parse sanitized string with marker \""
          <> variable_marker
          <> "\" from "
          <> string.inspect(graphemes),
        )
      }()
  })

  let unconsumed_graphemes = list.drop(graphemes, 3 + string.length(vars))

  #(vars, unconsumed_graphemes)
}

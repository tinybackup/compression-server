import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import lib/form_metadata
import simplifile

pub fn image(image: BitArray) {
  use footer <- result.try(form_metadata.read_image_footer(image))

  use baseline <- result.try(bit_array.slice(
    from: image,
    at: 0,
    take: footer.baseline_length,
  ))

  use metadata <- result.try(bit_array.slice(
    from: image,
    at: footer.baseline_length,
    take: footer.metadata_length,
  ))

  Ok(metadata)
}

/// Useful mostly for debugging purposes. Will separate all parts of the 
/// concatenated file and write them to disk for inspection.
@internal
pub fn image_to_parts_to_disk(image: BitArray) {
  use footer <- result.try(form_metadata.read_image_footer(image))

  use baseline <- result.try(bit_array.slice(
    from: image,
    at: 0,
    take: footer.baseline_length,
  ))

  use _ <- result.try(
    simplifile.write_bits("baseline.avif", baseline)
    |> result.replace_error(Nil),
  )

  use metadata <- result.try(bit_array.slice(
    from: image,
    at: footer.baseline_length,
    take: footer.metadata_length,
  ))

  use _ <- result.try(
    simplifile.write_bits("metadata.txt", metadata)
    |> result.replace_error(Nil),
  )

  let #(face_length, faces) =
    list.map_fold(
      over: footer.face_lengths,
      from: 0,
      with: fn(acc, face_length) {
        #(
          acc + face_length,
          bit_array.slice(
            from: image,
            at: footer.baseline_length + footer.metadata_length + acc,
            take: face_length,
          ),
        )
      },
    )

  use faces <- result.try(faces |> result.all)

  list.index_map(faces, fn(face, index) {
    simplifile.write_bits("face" <> index |> int.to_string <> ".avif", face)
    |> result.replace_error(Nil)
  })

  let #(focus_point_length, focus_points) =
    list.map_fold(
      over: footer.focus_point_lengths,
      from: 0,
      with: fn(acc, focus_point_length) {
        #(
          acc + focus_point_length,
          bit_array.slice(
            from: image,
            at: footer.baseline_length
              + footer.metadata_length
              + face_length
              + acc,
            take: focus_point_length,
          ),
        )
      },
    )

  use focus_points <- result.try(focus_points |> result.all)

  list.index_map(focus_points, fn(focus_point, index) {
    simplifile.write_bits(
      "focus_point" <> index |> int.to_string <> ".avif",
      focus_point,
    )
    |> result.replace_error(Nil)
  })

  let #(_, details) =
    list.map_fold(
      over: footer.detail_lengths,
      from: 0,
      with: fn(acc, detail_length) {
        #(
          acc + detail_length,
          bit_array.slice(
            from: image,
            at: footer.baseline_length
              + footer.metadata_length
              + face_length
              + focus_point_length
              + acc,
            take: detail_length,
          ),
        )
      },
    )

  use details <- result.try(details |> result.all)

  list.index_map(details, fn(detail, index) {
    simplifile.write_bits("detail" <> index |> int.to_string <> ".avif", detail)
    |> result.replace_error(Nil)
  })

  Ok(Nil)
}

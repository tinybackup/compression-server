import ansel/fixed_bounding_box
import ansel/image
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import lib/downsize
import lib/form_metadata
import simplifile
import snag

pub fn image(image: BitArray) {
  use #(baseline, metadata, faces, focus_points, details) <- result.try(
    image_to_parts(image)
    |> result.replace_error(snag.new(
      "Failed to split image into parts read image",
    )),
  )

  use baseline <- result.try(image.from_bit_array(baseline))

  use metadata <- result.try(
    form_metadata.parse_image_metadata(metadata)
    |> result.replace_error(snag.new("Failed to parse metadata")),
  )

  use faces <- result.try(list.map(faces, image.from_bit_array) |> result.all)
  use focus_points <- result.try(
    list.map(focus_points, image.from_bit_array) |> result.all,
  )
  use details <- result.try(
    list.map(details, image.from_bit_array) |> result.all,
  )

  use restored <- result.try(downsize.restore_image(
    baseline,
    to: metadata.baseline_size,
  ))

  use restored <- result.try(
    restored
    |> apply(extractions: focus_points, at: metadata.focus_point_bounding_boxes),
  )

  use restored <- result.try(
    restored
    |> apply(extractions: faces, at: metadata.face_bounding_boxes),
  )

  restored
  |> apply(extractions: details, at: metadata.detail_bounding_boxes)
}

fn image_to_parts(image: BitArray) {
  use footer <- result.try(form_metadata.parse_image_footer(image))

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

  use details <- result.map(details |> result.all)

  #(baseline, metadata, faces, focus_points, details)
}

/// Useful mostly for debugging purposes. Will separate all parts of the 
/// concatenated file and write them to disk for inspection.
@internal
pub fn image_to_parts_to_disk(image: BitArray) {
  use #(baseline, metadata, faces, focus_points, details) <- result.try(
    image_to_parts(image),
  )

  use _ <- result.try(
    simplifile.write_bits("baseline.avif", baseline)
    |> result.nil_error,
  )

  use _ <- result.try(
    simplifile.write_bits("metadata.txt", metadata)
    |> result.nil_error,
  )

  list.index_map(faces, fn(face, index) {
    simplifile.write_bits("face" <> index |> int.to_string <> ".avif", face)
    |> result.nil_error
  })

  list.index_map(focus_points, fn(focus_point, index) {
    simplifile.write_bits(
      "focus_point" <> index |> int.to_string <> ".avif",
      focus_point,
    )
    |> result.nil_error
  })

  list.index_map(details, fn(detail, index) {
    simplifile.write_bits("detail" <> index |> int.to_string <> ".avif", detail)
    |> result.nil_error
  })

  Ok(Nil)
}

fn apply(image, extractions extractions, at bbs) {
  list.zip(extractions, bbs)
  |> list.fold(from: Ok(image), with: fn(res, face_bb) {
    case res {
      Ok(restored) -> {
        let #(face, bb) = face_bb
        let #(x, y, _, _) = fixed_bounding_box.to_ltwh_tuple(bb)

        image.composite_over(restored, face, at_left: x, at_top: y)
      }
      e -> e
    }
  })
}

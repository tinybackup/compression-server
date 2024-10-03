import ansel
import ansel/fixed_bounding_box
import ansel/image
import compression_server/types as core_types
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import snag

pub fn from_image(
  image: ansel.Image,
  faces: List(fixed_bounding_box.FixedBoundingBox),
) -> Result(List(core_types.ExtractedArea), snag.Snag) {
  let image_width = image.get_width(image)
  let image_height = image.get_height(image)

  let image_smallest_dimension =
    int.min(image_width, image_height) |> int.to_float

  list.map(faces, fn(face) {
    let expanded_face = fixed_bounding_box.expand(face, 10)

    // If the smallest dimension of the face is less than 8% of the
    // smallest dimension of the image, then expand the face area to 
    // try and include the entire body since this is a far away shot
    let #(face_left, face_top, face_width, face_height) =
      fixed_bounding_box.to_ltwh_tuple(expanded_face)

    let face_smallest_dimension =
      int.min(face_width, face_height) |> int.to_float

    let expanded_face = case
      face_smallest_dimension /. image_smallest_dimension <. 0.08
    {
      True ->
        fixed_bounding_box.LTWH(
          left: int.max(
            0,
            face_left - float.truncate(face_smallest_dimension *. 1.5),
          ),
          top: int.max(
            0,
            face_top - float.truncate(face_smallest_dimension *. 0.75),
          ),
          width: int.min(
            image_width,
            float.truncate(
              face_smallest_dimension +. { face_smallest_dimension *. 3.0 },
            ),
          ),
          height: int.min(
            image_height,
            float.truncate(
              face_smallest_dimension +. { face_smallest_dimension *. 11.0 },
            ),
          ),
        )

      False -> expanded_face
    }

    use expanded_face <- result.try(
      image.fit_fixed_bounding_box(expanded_face, in: image)
      |> result.replace_error(snag.new("Failed to fit face box in image")),
    )

    use face <- result.map(image.extract_area(from: image, at: expanded_face))

    core_types.ExtractedArea(area: face, bounding_box: expanded_face)
  })
  |> result.all
  |> snag.context("Failed to extract faces from image")
}

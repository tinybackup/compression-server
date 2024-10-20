//// Extracts small squares of high quality from the four corners of the
//// to preserve details that may not be in faces or the focus of the image.
//// Things like the texture of a shirt or pattern in the background.

import ansel
import ansel/bounding_box
import ansel/image
import compression_server/types as core_types
import gleam/int
import gleam/list
import gleam/result
import snag

/// Half the size of the detail crop. If this value is 32, the detail
/// crop will be 64x64 pixels.
const detail_crop_half_size = 32

pub fn from_image(image: ansel.Image) {
  let width = image.get_width(image)
  let height = image.get_height(image)

  let smallest_dimension = int.min(width, height)

  let get_bounding_box = fn(center_x, center_y) {
    bounding_box.ltrb(
      left: center_x - detail_crop_half_size,
      top: center_y - detail_crop_half_size,
      right: center_x + detail_crop_half_size,
      bottom: center_y + detail_crop_half_size,
    )
  }

  use detail_bounding_boxes <- result.try(
    [
      // Top-left quadrant center
      get_bounding_box(smallest_dimension / 4, smallest_dimension / 4),
      // Top-right quadrant center
      get_bounding_box(
        width - { smallest_dimension / 4 },
        smallest_dimension / 4,
      ),
      // Bottom-left quadrant center 
      get_bounding_box(
        smallest_dimension / 4,
        height - { smallest_dimension / 4 },
      ),
      // Bottom-right quadrant center
      get_bounding_box(
        width - { smallest_dimension / 4 },
        height - { smallest_dimension / 4 },
      ),
    ]
    |> result.all,
  )

  list.map(detail_bounding_boxes, fn(bounding_box) {
    use crop <- result.map(image.extract_area(from: image, at: bounding_box))

    core_types.ExtractedArea(area: crop, bounding_box: bounding_box)
  })
  |> result.all
  |> snag.context("Failed to extract details from image")
}

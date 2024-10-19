import ansel
import ansel/bounding_box
import ansel/image
import compression_server/types as core_types
import gleam/float
import gleam/int
import gleam/list
import gleam/result
import snag

/// Calculate the xywh of the focus crops to make an "oval" shape 
/// out of two large rectangles (cropped into three so they don't overlap) 
/// in the center of the image.
pub fn from_image(image: ansel.Image, focus_percent: Float) {
  // Like this for a vertical image:
  // ---------------
  // -----&@@@&-----
  // -----@@@@@-----
  // ---&$$$$$$$&---
  // ---$$$$$$$$$---
  // ---$$$$$$$$$---
  // ---$$$$$$$$$---
  // ---&$$$$$$$&---
  // -----%%%%%-----
  // -----&%%%&-----
  // ---------------
  // 
  // Or like this for a horizontal image:
  //
  // ------------------------
  // ------&$$$$$$$$$$&------
  // --&@@@$$$$$$$$$$$$%%%&--
  // --&@@@$$$$$$$$$$$$%%%&--
  // ------&$$$$$$$$$$&------
  // ------------------------
  //
  // Where "@", "$", and "%" are the three different focus crops and "&" 
  // represents a corner of one of the two large rectangles. For
  // compression I think we want to have as square crops as possible, but
  // this could be tested.

  let image_width = image.get_width(image)
  let image_height = image.get_height(image)

  let horizontal_crop_width = int.to_float(image_width) *. focus_percent
  let vertical_crop_height = int.to_float(image_height) *. focus_percent

  let vertical_crop_width = { horizontal_crop_width *. 0.67 } |> float.truncate
  let horizontal_crop_hight = { vertical_crop_height *. 0.67 } |> float.truncate

  let horizontal_crop_width = float.truncate(horizontal_crop_width)
  let vertical_crop_height = float.truncate(vertical_crop_height)

  use horizontal_crop <- result.try(
    bounding_box.ltwh(
      left: { image_width - horizontal_crop_width } / 2,
      top: { image_height - horizontal_crop_hight } / 2,
      width: horizontal_crop_width,
      height: horizontal_crop_hight,
    )
    |> result.replace_error(snag.new("Failed to create horizontal bounding box")),
  )
  use vertical_crop <- result.try(
    bounding_box.ltwh(
      left: { image_width - vertical_crop_width } / 2,
      top: { image_height - vertical_crop_height } / 2,
      width: vertical_crop_width,
      height: vertical_crop_height,
    )
    |> result.replace_error(snag.new("Failed to create vertical bounding box")),
  )

  let focus_point_bounding_boxes = case image_width > image_height {
    True -> [
      vertical_crop,
      ..bounding_box.cut(out_of: horizontal_crop, with: vertical_crop)
    ]
    False -> [
      horizontal_crop,
      ..bounding_box.cut(out_of: vertical_crop, with: horizontal_crop)
    ]
  }

  list.map(focus_point_bounding_boxes, fn(bounding_box) {
    use crop <- result.map(image.extract_area(from: image, at: bounding_box))

    core_types.ExtractedArea(area: crop, bounding_box: bounding_box)
  })
  |> result.all
  |> snag.context("Failed to extract focus points from image")
}

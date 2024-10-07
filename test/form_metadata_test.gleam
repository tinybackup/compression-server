import ansel/fixed_bounding_box
import compression_server/lib/form_metadata
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import tempo/naive_datetime
import tempo/offset

pub fn main() {
  gleeunit.main()
}

fn assert_ltwh(x, y, w, h) {
  let assert Ok(bb) = fixed_bounding_box.ltwh(x, y, w, h)
  bb
}

pub fn parse_footer_test() {
  let footer = <<
    "tbdv01b6680m200f3286f3458f1396p3565p703p1375d492d735d787d626tbdv0100060",
  >>

  form_metadata.parse_image_footer(footer)
  |> should.equal(
    Ok(
      form_metadata.ImageFooter(
        baseline_length: 6680,
        metadata_length: 200,
        face_lengths: [3286, 3458, 1396],
        focus_point_lengths: [3565, 703, 1375],
        detail_lengths: [492, 735, 787, 626],
      ),
    ),
  )
}

pub fn parse_footer_no_faces_test() {
  let footer = <<"tbdv01b6680m200p3565p703p1375d492d735d787d626tbdv0100045">>

  form_metadata.parse_image_footer(footer)
  |> should.equal(
    Ok(
      form_metadata.ImageFooter(
        baseline_length: 6680,
        metadata_length: 200,
        face_lengths: [],
        focus_point_lengths: [3565, 703, 1375],
        detail_lengths: [492, 735, 787, 626],
      ),
    ),
  )
}

pub fn parse_missing_footer_test() {
  let footer = <<"Stop! You have violated the law!">>

  form_metadata.parse_image_footer(footer)
  |> should.be_error
}

pub fn parse_unknown_char_footer_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0100060",
  >>

  form_metadata.parse_image_footer(footer)
  |> should.be_error
}

pub fn parse_bad_footer_size_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0100260",
  >>

  form_metadata.parse_image_footer(footer)
  |> should.be_error
}

pub fn parse_bad_footer_size_size_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0160",
  >>

  form_metadata.parse_image_footer(footer)
  |> should.be_error
}

pub fn parse_image_metadata_single_face_test() {
  let metadata = <<
    "tbdv01b1080t2024-10-03T12:54:00z:a\"input.jpg\"v0u\"\"f361,313,208,624p223,377,364,325p283,297,244,80p283,702,244,81d170,170,64,64d576,170,64,64d170,846,64,64d576,846,64,64",
  >>

  form_metadata.parse_image_metadata(metadata)
  |> should.equal(
    Ok(form_metadata.ImageMetadata(
      baseline_size: 1080,
      face_bounding_boxes: [assert_ltwh(361, 313, 208, 624)],
      focus_point_bounding_boxes: [
        assert_ltwh(223, 377, 364, 325),
        assert_ltwh(283, 297, 244, 80),
        assert_ltwh(283, 702, 244, 81),
      ],
      detail_bounding_boxes: [
        assert_ltwh(170, 170, 64, 64),
        assert_ltwh(576, 170, 64, 64),
        assert_ltwh(170, 846, 64, 64),
        assert_ltwh(576, 846, 64, 64),
      ],
      datetime: naive_datetime.literal("2024-10-03T12:54:00"),
      datetime_offset: None,
      original_file_path: "input.jpg",
      is_favorite: False,
      user_metadata: "",
    )),
  )
}

pub fn parse_image_metadata_no_face_test() {
  let metadata = <<
    "tbdv01b1080t2024-10-03T12:54:00z:a\"input.jpg\"v0u\"\"p223,377,364,325p283,297,244,80p283,702,244,81d170,170,64,64d576,170,64,64d170,846,64,64d576,846,64,64",
  >>

  form_metadata.parse_image_metadata(metadata)
  |> should.equal(
    Ok(form_metadata.ImageMetadata(
      baseline_size: 1080,
      face_bounding_boxes: [],
      focus_point_bounding_boxes: [
        assert_ltwh(223, 377, 364, 325),
        assert_ltwh(283, 297, 244, 80),
        assert_ltwh(283, 702, 244, 81),
      ],
      detail_bounding_boxes: [
        assert_ltwh(170, 170, 64, 64),
        assert_ltwh(576, 170, 64, 64),
        assert_ltwh(170, 846, 64, 64),
        assert_ltwh(576, 846, 64, 64),
      ],
      datetime: naive_datetime.literal("2024-10-03T12:54:00"),
      datetime_offset: None,
      original_file_path: "input.jpg",
      is_favorite: False,
      user_metadata: "",
    )),
  )
}

pub fn parse_image_metadata2_test() {
  let metadata = <<
    "tbdv01b780t2023-09-13T01:55:01z-04:00a\"input.jpg\"v1u\"Desc:'Hi' He said to me\"p223,377,364,325p283,297,244,80p283,702,244,81d170,170,64,64d576,170,64,64d170,846,64,64d576,846,64,64",
  >>

  form_metadata.parse_image_metadata(metadata)
  |> should.equal(
    Ok(form_metadata.ImageMetadata(
      baseline_size: 780,
      face_bounding_boxes: [],
      focus_point_bounding_boxes: [
        assert_ltwh(223, 377, 364, 325),
        assert_ltwh(283, 297, 244, 80),
        assert_ltwh(283, 702, 244, 81),
      ],
      detail_bounding_boxes: [
        assert_ltwh(170, 170, 64, 64),
        assert_ltwh(576, 170, 64, 64),
        assert_ltwh(170, 846, 64, 64),
        assert_ltwh(576, 846, 64, 64),
      ],
      datetime: naive_datetime.literal("2023-09-13T01:55:01"),
      datetime_offset: Some(offset.literal("-04:00")),
      original_file_path: "input.jpg",
      is_favorite: True,
      user_metadata: "Desc:'Hi' He said to me",
    )),
  )
}

pub fn parse_image_metadata3_test() {
  let metadata = <<
    "tbdv01b780t2023-09-13T01:55:01z+04:53a\"backups/input.jpg\"v1u\"Desc:hi@me.com\"",
  >>

  form_metadata.parse_image_metadata(metadata)
  |> should.equal(
    Ok(form_metadata.ImageMetadata(
      baseline_size: 780,
      face_bounding_boxes: [],
      focus_point_bounding_boxes: [],
      detail_bounding_boxes: [],
      datetime: naive_datetime.literal("2023-09-13T01:55:01"),
      datetime_offset: Some(offset.literal("+04:53")),
      original_file_path: "backups/input.jpg",
      is_favorite: True,
      user_metadata: "Desc:hi@me.com",
    )),
  )
}

pub fn parse_bad_metadata_test() {
  let metadata = <<
    "tbdv01t2023-09-13T01:55:01z+04:53a\"backups/input.jpg\"v1u\"\"",
  >>

  form_metadata.parse_image_metadata(metadata)
  |> should.be_error
}

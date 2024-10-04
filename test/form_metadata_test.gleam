import gleeunit
import gleeunit/should
import lib/form_metadata

pub fn main() {
  gleeunit.main()
}

pub fn parse_footer_test() {
  let footer = <<
    "tbdv01b6680m200f3286f3458f1396p3565p703p1375d492d735d787d626tbdv0100060",
  >>

  form_metadata.read_image_footer(footer)
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

  form_metadata.read_image_footer(footer)
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

  form_metadata.read_image_footer(footer)
  |> should.equal(Error(Nil))
}

pub fn parse_unknown_char_footer_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0100060",
  >>

  form_metadata.read_image_footer(footer)
  |> should.equal(Error(Nil))
}

pub fn parse_bad_footer_size_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0100260",
  >>

  form_metadata.read_image_footer(footer)
  |> should.equal(Error(Nil))
}

pub fn parse_bad_footer_size_size_test() {
  let footer = <<
    "tbdv01b6680m200v3286v3458v1396p3565p703p1375d492d735d787d626tbdv0160",
  >>

  form_metadata.read_image_footer(footer)
  |> should.equal(Error(Nil))
}

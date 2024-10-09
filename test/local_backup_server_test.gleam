import backup_server/local_server
import compression_server/types
import gleam/option.{None}
import gleeunit
import gleeunit/should
import simplifile
import tempo/naive_datetime

pub fn main() {
  gleeunit.main()
}

pub fn backup_path_test() {
  local_server.get_backup_path(
    "/tinybackup/backup",
    534_234_532,
    types.Tiny,
  )
  |> should.equal("/tinybackup/backup/1/f/d/1fd7c5a4.tinybackup.avif")
}

pub fn determine_datetime_from_exif_test() {
  let assert Ok(file_bits) =
    simplifile.read_bits("test/resources/contains_exif.jpeg")

  local_server.determine_date(file_bits, "photos/cool.jpeg")
  |> should.equal(Ok(#(naive_datetime.literal("2024-05-01T18:03:58"), None)))
}

pub fn determine_date_from_file_path_test() {
  let assert Ok(file_bits) =
    simplifile.read_bits("test/resources/contains_nothing.jpeg")

  local_server.determine_date(file_bits, "photos/2024.06.21 My Pic.jpeg")
  |> should.equal(Ok(#(naive_datetime.literal("2024-06-21T00:00:00"), None)))
}

pub fn determine_datetime_from_file_path_test() {
  let assert Ok(file_bits) =
    simplifile.read_bits("test/resources/contains_nothing.jpeg")

  local_server.determine_date(file_bits, "photos/20240621_053023.jpeg")
  |> should.equal(Ok(#(naive_datetime.literal("2024-06-21T05:30:23"), None)))
}

pub fn determine_datetime_from_sytem_date_test() {
  local_server.determine_date(
    <<>>,
    "test/resources/contains_nothing.jpeg",
  )
  |> should.equal(Ok(#(naive_datetime.literal("2024-10-09T15:38:55"), None)))
}

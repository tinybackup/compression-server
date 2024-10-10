import backup_server/file_cache
import backup_server/local_server
import compression_server/types
import gleam/list
import gleam/option.{None}
import gleeunit
import gleeunit/should
import simplifile
import tempo/naive_datetime

pub fn main() {
  gleeunit.main()
}

pub fn backup_path_test() {
  local_server.get_backup_path("/tinybackup/backup", "1fd7c5a4", types.Tiny)
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
  local_server.determine_date(<<>>, "test/resources/contains_nothing.jpeg")
  |> should.equal(Ok(#(naive_datetime.literal("2024-10-09T15:38:55"), None)))
}

pub fn add_new_file_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(conn, "test/input", "photo.jpg", "1fd7c5a4")
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(file_cache.FileEntry(dir, name, hash, status, _))) =
    file_cache.get_file_entry(conn, "test/input", "photo.jpg", "1fd7c5a4")

  #(dir, name, hash, status)
  |> should.equal(#("test/input", "photo.jpg", "1fd7c5a4", file_cache.New))
}

pub fn mark_file_as_stale_test() {
  file_cache.wipe_test_db()
  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(conn, "test/input", "photo.jpg", "1fd7c5a4")
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_stale(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(file_cache.FileEntry(dir, name, hash, status, _))) =
    file_cache.get_file_entry(conn, "test/input", "photo.jpg", "1fd7c5a4")

  #(dir, name, hash, status)
  |> should.equal(#("test/input", "photo.jpg", "1fd7c5a4", file_cache.Stale))
}

pub fn get_files_needing_backup_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  let assert Ok(files) = file_cache.get_files_needing_backup(conn)

  files
  |> should.equal([])

  file_cache.add_new_file(conn, "test/input", "photo.jpg", "1fd7c5a4")
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_stale(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(conn, "test/input", "photo2.jpg", "1fd7c5a3")
  |> should.equal(Ok(Nil))

  let assert Ok(files) = file_cache.get_files_needing_backup(conn)

  let files =
    list.map(files, fn(f) {
      let file_cache.FileEntry(dir, name, hash, status, _) = f
      #(dir, name, hash, status)
    })

  files
  |> should.equal([#("test/input", "photo2.jpg", "1fd7c5a3", file_cache.New)])
}

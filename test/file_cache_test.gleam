import backup_server/file_cache
import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import tempo/datetime

pub fn main() {
  gleeunit.main()
}

pub fn add_new_file_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(file_cache.FileEntry(dir, name, _, hash, status, _))) =
    file_cache.get_file_entry(conn, "test/input", "photo.jpg")

  #(dir, name, hash, status)
  |> should.equal(#("test/input", "photo.jpg", None, file_cache.New))
}

pub fn stale_files_test() {
  file_cache.wipe_test_db()
  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo2.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_stale(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  let assert Ok(stales) = file_cache.get_stale_files(conn)

  stales
  |> list.map(fn(f) { #(f.file_dir, f.file_name, f.hash, f.status) })
  |> should.equal([#("test/input", "photo.jpg", None, file_cache.Stale)])

  let assert Ok(stales) = file_cache.get_non_stale_files(conn)

  stales
  |> list.map(fn(f) { #(f.file_dir, f.file_name, f.hash, f.status) })
  |> should.equal([#("test/input", "photo2.jpg", None, file_cache.New)])
}

pub fn get_files_needing_backup_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  let assert Ok(files) = file_cache.get_files_needing_backup(conn)

  files
  |> should.equal([])

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_stale(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo2.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo3.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_failed(conn, "test/input", "photo3.jpg")
  |> should.equal(Ok(Nil))

  let assert Ok(files) = file_cache.get_files_needing_backup(conn)

  let files =
    list.map(files, fn(f) {
      let file_cache.FileEntry(dir, name, _, hash, status, _) = f
      #(dir, name, hash, status)
    })

  files
  |> should.equal([
    #("test/input", "photo2.jpg", None, file_cache.New),
    #("test/input", "photo3.jpg", None, file_cache.Failed),
  ])
}

pub fn get_file_entry_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_stale(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-10T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  let assert Ok(option.Some(file_cache.FileEntry(
    dir,
    name,
    mod_time,
    hash,
    status,
    _,
  ))) = file_cache.get_file_entry(conn, "test/input", "photo.jpg")

  #(dir, name, mod_time, hash, status)
  |> should.equal(#(
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-10T15:38:55Z"),
    None,
    file_cache.New,
  ))
}

pub fn reset_processing_files_test() {
  file_cache.wipe_test_db()
  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_processing(conn, "test/input", "photo.jpg")
  |> should.equal(Ok(Nil))

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo2.jpg",
    datetime.literal("2024-10-09T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_processing(conn, "test/input", "photo2.jpg")
  |> should.equal(Ok(Nil))

  file_cache.mark_file_as_backed_up(
    conn,
    "test/input",
    "photo2.jpg",
    "1fd7c564",
  )
  |> should.equal(Ok(Nil))

  let assert Ok(processing_files) = file_cache.get_files_needing_backup(conn)

  processing_files
  |> should.equal([])

  file_cache.reset_processing_files(conn)
  |> should.equal(Ok(Nil))

  let assert Ok(processing_files) = file_cache.get_files_needing_backup(conn)

  processing_files
  |> list.map(fn(f) { #(f.file_dir, f.file_name, f.hash, f.status) })
  |> should.equal([#("test/input", "photo.jpg", None, file_cache.New)])
}

pub fn check_file_is_backed_up_test() {
  file_cache.wipe_test_db()

  let assert Ok(conn) = file_cache.start_test()

  file_cache.add_new_file(
    conn,
    "test/input",
    "photo.jpg",
    datetime.literal("2024-10-10T15:38:55Z"),
  )
  |> should.equal(Ok(Nil))

  file_cache.check_file_is_backed_up(conn, "1fd7c564")
  |> should.equal(Ok(False))

  file_cache.mark_file_as_backed_up(conn, "test/input", "photo.jpg", "1fd7c564")
  |> should.equal(Ok(Nil))

  file_cache.check_file_is_backed_up(conn, "1fd7c564")
  |> should.equal(Ok(True))
}

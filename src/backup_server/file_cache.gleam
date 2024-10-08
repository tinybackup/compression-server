import ext/snagx
import filepath
import gleam/dynamic
import gleam/int
import gleam/result
import gleam/string
import simplifile
import sqlight

pub type FileEntry {
  FileEntry(file_path: String, hash: Int, status: FileStatus)
}

pub type FileStatus {
  New
  Processing
  Failed
  BackedUp
  Stale
}

pub fn add_new_file(conn, file_path, hash) {
  sqlight.exec(
    "INSERT INTO files ("
      <> files_sql_columns
      <> ") VALUES ("
      <> ["'" <> file_path <> "'", int.to_string(hash), "'NEW'"]
    |> string.join(",")
      <> ")",
    on: conn,
  )
  |> snagx.from_error(
    "Unable to insert new file into file cache db " <> file_path,
  )
}

pub fn mark_file_as_stale(conn, file_path) {
  sqlight.exec(
    "UPDATE files SET status = 'STALE' WHERE file_path = '" <> file_path <> "'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as stale in file cache db")
}

pub fn mark_file_as_processing(conn, file_path) {
  sqlight.exec(
    "UPDATE files SET status = 'PROCESSING' WHERE file_path = '"
      <> file_path
      <> "' AND status = 'NEW'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as processing in file cache db")
}

pub fn mark_file_as_failed(conn, file_path) {
  sqlight.exec(
    "UPDATE files SET status = 'PROCESSING' WHERE file_path = '"
      <> file_path
      <> "' AND status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as failed in file cache db")
}

pub fn mark_file_as_backed_up(conn, file_path) {
  sqlight.exec(
    "UPDATE files SET status = 'BACKED_UP' WHERE file_path = '"
      <> file_path
      <> "' AND status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as failed in file cache db")
}

pub fn get_all_db_files(conn) {
  sqlight.query(
    "SELECT " <> files_sql_columns <> " FROM files",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error("Failed to get all files from file cache db")
}

fn string_to_file_status(status: String) -> Result(FileStatus, Nil) {
  case status {
    "NEW" -> Ok(New)
    "PROCESSING" -> Ok(Processing)
    "FAILED" -> Ok(Failed)
    "BACKED_UP" -> Ok(BackedUp)
    "STALE" -> Ok(Stale)
    _ -> Error(Nil)
  }
}

fn file_entry_decoder(dy) {
  dynamic.decode3(
    FileEntry,
    dynamic.element(0, dynamic.string),
    dynamic.element(1, dynamic.int),
    dynamic.element(2, fn(dy) {
      use str <- result.try(dynamic.string(dy))
      string_to_file_status(str)
      |> result.replace_error([dynamic.DecodeError("status", str, ["2"])])
    }),
  )(dy)
}

const files_db_path = "data/files.db"

const files_sql_columns = "
  id, file_path, status
"

const create_files_table_stmt = "
CREATE TABLE IF NOT EXISTS files (
  file_path TEXT NOT NULL,
  hash INTEGER NOT NULL,
  status TEXT NOT NULL,
  PRIMARY KEY (file_path, hash)
)"

pub fn connect_to_files_db() {
  let _ =
    simplifile.create_directory_all(filepath.directory_name(files_db_path))

  use conn <- result.map(
    sqlight.open("file:" <> files_db_path)
    |> snagx.from_error("Failed to connect to file cache db " <> files_db_path),
  )

  let _ = sqlight.exec(create_files_table_stmt, on: conn)

  conn
}

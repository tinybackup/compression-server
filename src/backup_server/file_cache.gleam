import ext/snagx
import filepath
import gleam/dynamic
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import simplifile
import sqlight

pub type FileEntry {
  FileEntry(file_dir: String, file_name: String, hash: Int, status: FileStatus)
}

pub type FileStatus {
  New
  Processing
  Failed
  BackedUp
  Stale
}

pub fn add_new_file(conn, file_dir, file_name, hash) {
  sqlight.exec(
    "INSERT INTO files ("
      <> files_sql_columns
      <> ") VALUES ("
      <> [
      "'" <> file_dir <> "'",
      "'" <> file_name <> "'",
      int.to_string(hash),
      "'NEW'",
    ]
    |> string.join(",")
      <> ")",
    on: conn,
  )
  |> snagx.from_error(
    "Unable to insert new file into file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
}

pub fn mark_file_as_stale(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'STALE' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as stale in file cache db")
}

pub fn mark_file_as_processing(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'PROCESSING' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'NEW'",
    on: conn,
  )
  |> snagx.from_error("Unable to mark file as processing in file cache db")
}

pub fn mark_file_as_failed(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'PROCESSING' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error("Failed to mark file as failed in file cache db")
}

pub fn mark_file_as_backed_up(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'BACKED_UP' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error(
    "Failed to mark file as backed up in file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
}

pub fn get_non_stale_files(conn) {
  sqlight.query(
    "SELECT " <> files_sql_columns <> " FROM files WHERE status != 'STALE'",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error("Failed to get non stale files from file cache db")
}

pub fn get_stale_files(conn) {
  sqlight.query(
    "SELECT " <> files_sql_columns <> " FROM files WHERE status = 'STALE'",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error("Failed to get stale files from file cache db")
}

pub fn get_file_entry(conn, file_dir, file_name, hash) {
  use res <- result.map(
    sqlight.query(
      "SELECT "
        <> files_sql_columns
        <> " FROM files WHERE file_dir = '"
        <> file_dir
        <> "' AND file_name = '"
        <> file_name
        <> "' AND hash = "
        <> int.to_string(hash),
      on: conn,
      with: [],
      expecting: file_entry_decoder,
    )
    |> snagx.from_error(
      "Failed to get file entry from file cache db "
      <> file_dir
      <> "/"
      <> file_name,
    ),
  )

  list.first(res)
  |> result.map(Some)
  |> result.unwrap(None)
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
  dynamic.decode4(
    FileEntry,
    dynamic.element(0, dynamic.string),
    dynamic.element(1, dynamic.string),
    dynamic.element(2, dynamic.int),
    dynamic.element(3, fn(dy) {
      use str <- result.try(dynamic.string(dy))
      string_to_file_status(str)
      |> result.replace_error([dynamic.DecodeError("status", str, ["2"])])
    }),
  )(dy)
}

const files_db_path = "data/files.db"

const files_sql_columns = "file_dir, file_name, hash, status"

const create_files_table_stmt = "
CREATE TABLE IF NOT EXISTS files (
  file_dir TEXT NOT NULL,
  file_name TEXT NOT NULL,
  hash INTEGER NOT NULL,
  status TEXT NOT NULL,
  PRIMARY KEY (file_dir, file_name, hash)
)"

pub fn connect_to_files_db(read_only read_only: Bool) {
  let _ =
    simplifile.create_directory_all(filepath.directory_name(files_db_path))

  let mode = case read_only {
    True -> "?mode=ro"
    False -> ""
  }

  use conn <- result.map(
    sqlight.open("file:" <> files_db_path <> mode)
    |> snagx.from_error("Failed to connect to file cache db " <> files_db_path),
  )

  let _ = sqlight.exec(create_files_table_stmt, on: conn)

  conn
}

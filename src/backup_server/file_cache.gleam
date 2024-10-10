import ext/snagx
import filepath
import gleam/dynamic
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import simplifile
import snag
import sqlight
import tempo
import tempo/datetime

pub type FileEntry {
  FileEntry(
    file_dir: String,
    file_name: String,
    hash: String,
    status: FileStatus,
    entry_mod_time: tempo.DateTime,
  )
}

pub type FileStatus {
  New
  Processing
  Failed
  BackedUp
  Stale
  Deleted
}

pub type FileCacheRequest {
  AddNewFile(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
    hash: String,
  )
  MarkFileAsStale(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
  )
  MarkFileAsDeleted(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
  )
  MarkFileAsProcessing(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
  )
  MarkFileAsFailed(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
  )
  MarkFileAsBackedUp(
    reply: process.Subject(Result(Nil, snag.Snag)),
    file_dir: String,
    file_name: String,
  )
  GetNonStaleFiles(reply: process.Subject(Result(List(FileEntry), snag.Snag)))
  GetStaleFiles(reply: process.Subject(Result(List(FileEntry), snag.Snag)))
  GetFilesNeedingBackup(
    reply: process.Subject(Result(List(FileEntry), snag.Snag)),
  )
  GetFileEntry(
    reply: process.Subject(Result(option.Option(FileEntry), snag.Snag)),
    file_dir: String,
    file_name: String,
    hash: String,
  )
  ResetProcessingFiles(reply: process.Subject(Result(Nil, snag.Snag)))
}

pub const db_timeout = 10_000_000

pub fn start() {
  use conn <- result.try(connect_to_files_db(read_only: False))

  actor.start(conn, handle_msg)
  |> snagx.from_error("Unable to start file cache actor")
}

fn handle_msg(msg, conn) {
  case msg {
    AddNewFile(reply, file_dir, file_name, hash) ->
      process.send(reply, do_add_new_file(conn, file_dir, file_name, hash))

    MarkFileAsStale(reply, file_dir, file_name) ->
      process.send(reply, do_mark_file_as_stale(conn, file_dir, file_name))

    MarkFileAsDeleted(reply, file_dir, file_name) ->
      process.send(reply, do_mark_file_as_deleted(conn, file_dir, file_name))

    MarkFileAsProcessing(reply, file_dir, file_name) ->
      process.send(reply, do_mark_file_as_processing(conn, file_dir, file_name))

    MarkFileAsFailed(reply, file_dir, file_name) ->
      process.send(reply, do_mark_file_as_failed(conn, file_dir, file_name))

    MarkFileAsBackedUp(reply, file_dir, file_name) ->
      process.send(reply, do_mark_file_as_backed_up(conn, file_dir, file_name))

    GetNonStaleFiles(reply) -> process.send(reply, do_get_non_stale_files(conn))

    GetStaleFiles(reply) -> process.send(reply, do_get_stale_files(conn))

    GetFilesNeedingBackup(reply) ->
      process.send(reply, do_get_files_needing_backup(conn))

    GetFileEntry(reply, file_dir, file_name, hash) ->
      process.send(reply, do_get_file_entry(conn, file_dir, file_name, hash))

    ResetProcessingFiles(reply) ->
      process.send(reply, do_reset_processing_files(conn))
  }

  actor.continue(conn)
}

pub fn add_new_file(conn, file_dir, file_name, hash) {
  let reply = process.new_subject()
  actor.send(conn, AddNewFile(reply, file_dir, file_name, hash))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Add new file operation timed out")
  |> result.flatten
}

fn do_add_new_file(conn, file_dir, file_name, hash) {
  sqlight.exec(
    "INSERT INTO files ("
      <> files_sql_columns
      <> ") VALUES ("
      <> [
      "'" <> file_dir <> "'",
      "'" <> file_name <> "'",
      "'" <> hash <> "'",
      "'NEW'",
      "'" <> datetime.now_local() |> datetime.to_string <> "'",
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
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsStale(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as stale operation timed out")
  |> result.flatten
}

fn do_mark_file_as_stale(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'STALE', entry_mod_time = '"
      <> datetime.now_local() |> datetime.to_string
      <> "' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "'",
    on: conn,
  )
  |> snagx.from_error(
    "Failed to mark file as stale in file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
}

pub fn mark_file_as_deleted(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsDeleted(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as deleted operation timed out")
  |> result.flatten
}

fn do_mark_file_as_deleted(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'DELETED', entry_mod_time = '"
      <> datetime.now_local() |> datetime.to_string
      <> "' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'BACKED_UP'",
    on: conn,
  )
  |> snagx.from_error(
    "Failed to mark file as deleted in file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
}

pub fn mark_file_as_processing(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsProcessing(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as processing operation timed out")
  |> result.flatten
}

fn do_mark_file_as_processing(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'PROCESSING', entry_mod_time = '"
      <> datetime.now_local() |> datetime.to_string
      <> "' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'NEW'",
    on: conn,
  )
  |> snagx.from_error(
    "Failed to mark file as processing in file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
}

pub fn mark_file_as_failed(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsFailed(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as failed operation timed out")
  |> result.flatten
}

fn do_mark_file_as_failed(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'FAILED', entry_mod_time = '"
      <> datetime.now_local() |> datetime.to_string
      <> "' WHERE file_dir = '"
      <> file_dir
      <> "' AND file_name = '"
      <> file_name
      <> "' AND status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error("Failed to mark file as failed in file cache db")
}

pub fn mark_file_as_backed_up(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsBackedUp(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as backed up operation timed out")
  |> result.flatten
}

fn do_mark_file_as_backed_up(conn, file_dir, file_name) {
  sqlight.exec(
    "UPDATE files SET status = 'BACKED_UP', entry_mod_time = '"
      <> datetime.now_local() |> datetime.to_string
      <> "' WHERE file_dir = '"
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

pub fn get_files_needing_backup(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetFilesNeedingBackup(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get files needing backup operation timed out")
  |> result.flatten
}

fn do_get_files_needing_backup(conn) {
  sqlight.query(
    "SELECT "
      <> files_sql_columns
      <> " FROM files WHERE status = 'NEW' OR status = 'FAILED'",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error(
    "Failed to get files needing to be backed up from file cache db",
  )
}

pub fn get_non_stale_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetNonStaleFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get non stale files operation timed out")
  |> result.flatten
}

fn do_get_non_stale_files(conn) {
  sqlight.query(
    "SELECT " <> files_sql_columns <> " FROM files WHERE status != 'STALE'",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error("Failed to get non stale files from file cache db")
}

pub fn get_stale_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetStaleFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get stale files operation timed out")
  |> result.flatten
}

fn do_get_stale_files(conn) {
  sqlight.query(
    "SELECT " <> files_sql_columns <> " FROM files WHERE status = 'STALE'",
    on: conn,
    with: [],
    expecting: file_entry_decoder,
  )
  |> snagx.from_error("Failed to get stale files from file cache db")
}

pub fn get_file_entry(conn, file_dir, file_name, hash) {
  let reply = process.new_subject()
  actor.send(conn, GetFileEntry(reply, file_dir, file_name, hash))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get file entry operation timed out")
  |> result.flatten
}

fn do_get_file_entry(conn, file_dir, file_name, hash) {
  use res <- result.map(
    sqlight.query(
      "SELECT "
        <> files_sql_columns
        <> " FROM files WHERE file_dir = '"
        <> file_dir
        <> "' AND file_name = '"
        <> file_name
        <> "' AND hash = '"
        <> hash
        <> "'",
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

pub fn reset_processing_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, ResetProcessingFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Reset processing files operation timed out")
  |> result.flatten
}

fn do_reset_processing_files(conn) {
  sqlight.exec(
    "UPDATE files SET status = 'NEW' WHERE status = 'PROCESSING'",
    on: conn,
  )
  |> snagx.from_error("Failed to reset processing files in file cache db")
}

fn string_to_file_status(status: String) -> Result(FileStatus, Nil) {
  case status {
    "NEW" -> Ok(New)
    "PROCESSING" -> Ok(Processing)
    "FAILED" -> Ok(Failed)
    "BACKED_UP" -> Ok(BackedUp)
    "STALE" -> Ok(Stale)
    "DELETED" -> Ok(Deleted)
    _ -> Error(Nil)
  }
}

fn file_entry_decoder(dy) {
  dynamic.decode5(
    FileEntry,
    dynamic.element(0, dynamic.string),
    dynamic.element(1, dynamic.string),
    dynamic.element(2, dynamic.string),
    dynamic.element(3, fn(dy) {
      use str <- result.try(dynamic.string(dy))
      string_to_file_status(str)
      |> result.replace_error([dynamic.DecodeError("status", str, ["2"])])
    }),
    dynamic.element(4, datetime.from_dynamic_string),
  )(dy)
}

const files_db_path = "data/files.db"

const files_sql_columns = "file_dir, file_name, hash, status, entry_mod_time"

const create_files_table_stmt = "
CREATE TABLE IF NOT EXISTS files (
  file_dir TEXT NOT NULL,
  file_name TEXT NOT NULL,
  hash TEXT NOT NULL,
  status TEXT NOT NULL,
  entry_mod_time TEXT NOT NULL,
  PRIMARY KEY (file_dir, file_name, hash)
)"

fn connect_to_files_db(read_only read_only: Bool) {
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

pub fn start_test() {
  use conn <- result.try(connect_to_test_files_db())

  actor.start(conn, handle_msg)
  |> snagx.from_error("Unable to start file cache actor")
}

fn connect_to_test_files_db() {
  let files_db_path = "data/files_test.db"
  let _ =
    simplifile.create_directory_all(filepath.directory_name(files_db_path))

  use conn <- result.map(
    sqlight.open("file:" <> files_db_path)
    |> snagx.from_error("Failed to connect to file cache db " <> files_db_path),
  )

  let _ = sqlight.exec(create_files_table_stmt, on: conn)

  conn
}

pub fn wipe_test_db() {
  let files_db_path = "data/files_test.db"
  let _ =
    simplifile.create_directory_all(filepath.directory_name(files_db_path))

  let assert Ok(conn) = sqlight.open("file:" <> files_db_path)

  let _ = sqlight.exec("DROP TABLE files", on: conn)

  Nil
}

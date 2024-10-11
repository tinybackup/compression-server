import ext/snagx
import filepath
import gleam/bool
import gleam/dynamic
import gleam/erlang/process
import gleam/io
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
    file_mod_time: tempo.DateTime,
    hash: option.Option(String),
    status: FileStatus,
    entry_time: tempo.DateTime,
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
    file_mod_time: tempo.DateTime,
    hash: option.Option(String),
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
  )
  CheckHashExists(reply: process.Subject(Result(Bool, snag.Snag)), hash: String)
  ResetProcessingFiles(reply: process.Subject(Result(Nil, snag.Snag)))
}

pub const db_timeout = 10_000_000

pub fn start(at backup_location) {
  use conn <- result.try(connect_to_files_db(backup_location))

  actor.start(conn, handle_msg)
  |> snagx.from_error("Unable to start file cache actor")
}

fn handle_msg(msg, conn) {
  case msg {
    AddNewFile(reply, file_dir:, file_name:, file_mod_time:, hash:) ->
      process.send(
        reply,
        do_add_new_record(conn, file_dir, file_name, file_mod_time, hash, New),
      )

    MarkFileAsStale(reply, file_dir:, file_name:) ->
      process.send(reply, do_mark_file_as(conn, file_dir, file_name, Stale))

    MarkFileAsDeleted(reply, file_dir:, file_name:) ->
      process.send(reply, do_mark_file_as(conn, file_dir, file_name, Deleted))

    MarkFileAsProcessing(reply, file_dir:, file_name:) ->
      process.send(
        reply,
        do_mark_file_as(conn, file_dir, file_name, Processing),
      )

    MarkFileAsFailed(reply, file_dir:, file_name:) ->
      process.send(reply, do_mark_file_as(conn, file_dir, file_name, Failed))

    MarkFileAsBackedUp(reply, file_dir:, file_name:) ->
      process.send(reply, do_mark_file_as(conn, file_dir, file_name, BackedUp))

    GetNonStaleFiles(reply) -> process.send(reply, do_get_non_stale_files(conn))

    GetStaleFiles(reply) -> process.send(reply, do_get_stale_files(conn))

    GetFilesNeedingBackup(reply) ->
      process.send(reply, do_get_files_needing_backup(conn))

    GetFileEntry(reply, file_dir:, file_name:) ->
      process.send(reply, do_get_file_entry(conn, file_dir, file_name))

    CheckHashExists(reply, hash) ->
      process.send(reply, do_check_file_is_backed_up(conn, hash))

    ResetProcessingFiles(reply) ->
      process.send(reply, do_reset_processing_files(conn))
  }

  actor.continue(conn)
}

pub fn add_new_file(conn, file_dir, file_name, file_mod_time, hash) {
  let reply = process.new_subject()
  actor.send(
    conn,
    AddNewFile(reply:, file_dir:, file_name:, file_mod_time:, hash:),
  )
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Add new file operation timed out")
  |> result.flatten
}

fn do_add_new_record(conn, file_dir, file_name, file_mod_time, hash, status) {
  sqlight.exec(
    "INSERT INTO files ("
      <> files_sql_columns
      <> ") VALUES ("
      <> [
      "'" <> file_dir <> "'",
      "'" <> file_name <> "'",
      "'" <> datetime.to_string(file_mod_time) <> "'",
      case hash {
        Some(hash) -> "'" <> hash <> "'"
        None -> "NULL"
      },
      "'" <> status_to_string(status) <> "'",
      "'" <> datetime.now_local() |> datetime.to_string <> "'",
    ]
    |> string.join(",")
      <> ")",
    on: conn,
  )
  |> snagx.from_error(
    "Unable to insert new "
    <> status_to_string(status)
    <> " file into file cache db "
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

pub fn mark_file_as_deleted(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsDeleted(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as deleted operation timed out")
  |> result.flatten
}

pub fn mark_file_as_processing(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsProcessing(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as processing operation timed out")
  |> result.flatten
}

pub fn mark_file_as_failed(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsFailed(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as failed operation timed out")
  |> result.flatten
}

pub fn mark_file_as_backed_up(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, MarkFileAsBackedUp(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Mark file as backed up operation timed out")
  |> result.flatten
}

fn do_mark_file_as(conn, file_dir, file_name, status) {
  use entry <- result.try(do_get_file_entry(conn, file_dir, file_name))
  use <- bool.guard(
    when: entry == None,
    return: snag.error(
      "Could not find file entry to mark as "
      <> status_to_string(status)
      <> " from "
      <> file_dir
      <> "/"
      <> file_name,
    ),
  )
  let assert Some(entry) = entry

  use error <- result.try_recover({
    do_add_new_record(
      conn,
      entry.file_dir,
      entry.file_name,
      entry.file_mod_time,
      entry.hash,
      status,
    )
  })

  error
  |> snag.layer(
    "Failed to add new "
    <> status_to_string(status)
    <> " record to the file cache db "
    <> file_dir
    <> "/"
    <> file_name,
  )
  |> Error
}

pub fn get_files_needing_backup(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetFilesNeedingBackup(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get files needing backup operation timed out")
  |> result.flatten
}

fn do_get_files_needing_backup(conn) {
  use entries <- result.map(
    get_file_entries(conn) |> snag.context("Failed to non stale file entries"),
  )

  list.filter(entries, fn(entry) {
    entry.status == New || entry.status == Failed
  })
}

pub fn get_non_stale_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetNonStaleFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get non stale files operation timed out")
  |> result.flatten
}

fn do_get_non_stale_files(conn) {
  use entries <- result.map(
    get_file_entries(conn) |> snag.context("Failed to non stale file entries"),
  )

  list.filter(entries, fn(entry) { entry.status != Stale })
}

pub fn get_stale_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, GetStaleFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get stale files operation timed out")
  |> result.flatten
}

fn do_get_stale_files(conn) {
  use entries <- result.map(
    get_file_entries(conn) |> snag.context("Failed to non stale file entries"),
  )

  list.filter(entries, fn(entry) { entry.status == Stale })
}

fn get_file_entries(conn) {
  sqlight.query("
      SELECT " <> files_sql_columns_complex <> "
      FROM files f
      JOIN (
        SELECT " <> files_sql_columns <> ", MAX(rowid) as max_rowid
        FROM files
        GROUP BY file_dir, file_name
      ) m ON f.rowid = m.max_rowid 
        AND f.file_dir = m.file_dir 
        AND f.file_name = m.file_name
    ", on: conn, with: [], expecting: file_entry_decoder)
  |> snagx.from_error("Failed to get file entries from file cache db")
}

pub fn get_file_entry(conn, file_dir, file_name) {
  let reply = process.new_subject()
  actor.send(conn, GetFileEntry(reply, file_dir, file_name))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Get file entry operation timed out")
  |> result.flatten
}

fn do_get_file_entry(conn, file_dir, file_name) {
  use res <- result.map(
    sqlight.query(
      "SELECT "
        <> files_sql_columns
        <> " FROM files WHERE file_dir = '"
        <> file_dir
        <> "' AND file_name = '"
        <> file_name
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

  list.sort(res, fn(a, b) { datetime.compare(b.entry_time, a.entry_time) })
  |> list.first
  |> result.map(Some)
  |> result.unwrap(None)
}

pub fn check_file_is_backed_up(conn, hash) {
  let reply = process.new_subject()
  actor.send(conn, CheckHashExists(reply, hash))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Check hash exists operation timed out")
  |> result.flatten
}

fn do_check_file_is_backed_up(conn, hash) {
  sqlight.query(
    "SELECT COUNT(*) FROM files WHERE status = 'BACKED_UP' AND hash = '"
      <> hash
      <> "'",
    on: conn,
    with: [],
    expecting: fn(dy) {
      use count <- result.map(dynamic.int(dy))
      count > 0
    },
  )
  |> snagx.from_error("Failed to check hash exists in file cache db")
  |> result.try(fn(count) {
    list.first(count) |> snagx.from_error("Unable to get hash count from db")
  })
}

pub fn reset_processing_files(conn) {
  let reply = process.new_subject()
  actor.send(conn, ResetProcessingFiles(reply))
  process.receive(reply, within: db_timeout)
  |> snagx.from_error("Reset processing files operation timed out")
  |> result.flatten
}

fn do_reset_processing_files(conn) {
  sqlight.exec("INSERT INTO files (
      file_dir, 
      file_name, 
      file_mod_time, 
      hash, 
      status, 
      entry_time
    ) SELECT 
      file_dir, 
      file_name, 
      file_mod_time, 
      hash, 
      'NEW', 
      '" <> datetime.now_local() |> datetime.to_string <> "'
    FROM files WHERE status = 'PROCESSING'", on: conn)
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

fn status_to_string(status) {
  case status {
    New -> "NEW"
    Processing -> "PROCESSING"
    Failed -> "FAILED"
    BackedUp -> "BACKED_UP"
    Stale -> "STALE"
    Deleted -> "DELETED"
  }
}

fn file_entry_decoder(dy) {
  dynamic.decode6(
    FileEntry,
    dynamic.element(0, dynamic.string),
    dynamic.element(1, dynamic.string),
    dynamic.element(2, datetime.from_dynamic_string),
    dynamic.element(3, dynamic.optional(dynamic.string)),
    dynamic.element(4, fn(dy) {
      use str <- result.try(dynamic.string(dy))
      string_to_file_status(str)
      |> result.replace_error([dynamic.DecodeError("status", str, ["2"])])
    }),
    dynamic.element(5, datetime.from_dynamic_string),
  )(dy)
}

const files_sql_columns = "
file_dir, 
file_name, 
file_mod_time, 
hash, 
status, 
entry_time
"

const files_sql_columns_complex = "
f.file_dir, 
f.file_name, 
f.file_mod_time, 
f.hash, 
f.status, 
f.entry_time
"

const create_files_table_stmt = "
CREATE TABLE IF NOT EXISTS files (
  file_dir TEXT NOT NULL,
  file_name TEXT NOT NULL,
  file_mod_time TEXT NOT NULL,
  hash TEXT,
  status TEXT NOT NULL,
  entry_time TEXT NOT NULL
)"

fn connect_to_files_db(path) {
  case simplifile.is_directory(path) {
    Ok(True) -> io.println("Using already existing backup location " <> path)
    _ -> io.println("Creating backup location " <> path)
  }

  let _ = simplifile.create_directory_all(path)

  use conn <- result.map(
    sqlight.open("file:" <> path <> "/files.db")
    |> snagx.from_error("Failed to connect to file cache db " <> path),
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
  let files_db_path = "test/data/files_test.db"
  use conn <- result.map(
    sqlight.open("file:" <> files_db_path)
    |> snagx.from_error("Failed to connect to file cache db " <> files_db_path),
  )

  let _ = sqlight.exec(create_files_table_stmt, on: conn)

  conn
}

pub fn wipe_test_db() {
  let files_db_path = "test/data/files_test.db"
  let _ =
    simplifile.create_directory_all(filepath.directory_name(files_db_path))

  let assert Ok(conn) = sqlight.open("file:" <> files_db_path)

  let _ = sqlight.exec("DROP TABLE files", on: conn)

  Nil
}

import ansel/image
import backup_server/file_cache
import compression_server/compress
import compression_server/lib/detect_faces
import compression_server/types
import ext/snagx
import filepath
import filespy
import gleam/bool
import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string
import glenvy/dotenv
import glenvy/env
import gsiphash
import repeatedly
import simplifile
import snag
import tempo
import tempo/datetime
import tempo/duration
import tempo/naive_datetime
import tempo/offset
import tempo/time

pub const file_hash_key = <<"8027f33215eaaba5">>

pub fn init_env() {
  use Nil <- result.try(
    dotenv.load() |> snagx.from_error("Failed to load .env"),
  )

  use backup_directories <- result.try({
    use dirs <- result.map(
      env.get_string("INPUT_FILE_LOCATIONS")
      |> snagx.from_error("Failed to get INPUT_FILE_LOCATIONS env var"),
    )
    string.split(dirs, ",")
  })

  use backup_base_path <- result.try(
    env.get_string("BACKUP_LOCATION")
    |> snagx.from_error("Failed to get BACKUP_LOCATION env var"),
  )

  use backup_mod_every_mins <- result.try(
    env.get_int("BACKUP_MODIFIED_FILES_EVERY_MINS")
    |> snagx.from_error(
      "Failed to get BACKUP_MODIFIED_FILES_EVERY_MINS env var",
    ),
  )

  use _ <- result.try(
    list.map(backup_directories, fn(dir) {
      case simplifile.is_directory(dir) {
        Ok(True) -> {
          io.println("Backing up directory " <> dir)
          Ok(Nil)
        }
        _ ->
          snag.error(
            "Input directory "
            <> dir
            <> " does not exist! These files can not be backed up, please set "
            <> "the INPUT_FILE_LOCATIONS env var to a comma separated list of "
            <> "valid directories to backup.",
          )
      }
    })
    |> result.all,
  )

  use file_cache_conn <- result.map(
    file_cache.start(at: backup_base_path)
    |> snagx.from_error("Failed to start file cache"),
  )

  #(
    backup_directories,
    backup_base_path,
    backup_mod_every_mins,
    file_cache_conn,
  )
}

pub type WatcherActorState {
  WatcherActorState(
    conn: process.Subject(file_cache.FileCacheRequest),
    file_mod_watcher: process.Subject(FileModWatcherMsg),
  )
}

pub fn init_watcher_actor(conn, input_directory_paths, backup_mod_every_mins) {
  use file_mod_watcher <- result.try(
    actor.start(
      FileModWatcherActorState(conn:, paths: set.new()),
      handle_mod_event,
    )
    |> snagx.from_error("Failed to start file mod watcher"),
  )

  repeatedly.call(backup_mod_every_mins * 60_000, Nil, fn(_, _) {
    process.send(file_mod_watcher, BackupMods)
  })

  use _ <- result.map(
    list.map(input_directory_paths, fn(directory_path) {
      reconcile_dir_with_db(directory_path, conn)
    })
    |> result.all
    |> snag.context("Failed to reconcile directories with db")
    |> snagx.from_error("Failed to init file system watcher"),
  )

  WatcherActorState(conn:, file_mod_watcher:)
}

/// Won't delete files from the backup that have been deleted since the
/// server was last running
pub fn reconcile_dir_with_db(directory_path, conn) {
  use new_disk_file_entries <- result.try(
    get_new_disk_files(directory_path, conn)
    |> snag.context("Failed to get new disk files"),
  )

  use _ <- result.map(
    list.map(new_disk_file_entries, fn(entry) {
      let #(file_dir, file_name, mod_time) = entry

      // If a file is new, then mark all other files (previously) at the same
      // path as stale.
      use _ <- result.try(file_cache.mark_file_as_stale(
        conn,
        file_dir,
        file_name,
      ))

      // Once the stale files are marked, then add this new one at the path
      // with the new status.
      file_cache.add_new_file(conn, file_dir, file_name, mod_time, None)
    })
    |> result.all
    |> snag.context("Failed to add new files to db"),
  )

  io.println("Reconciled directories with db")
  Nil
}

pub fn get_new_disk_files(directory_path, conn) {
  use file_paths <- result.try(
    simplifile.get_files(directory_path)
    |> snagx.from_simplifile("Failed to get files in " <> directory_path),
  )

  let #(disk_file_entries, disk_file_errors) =
    list.map(file_paths, fn(path) {
      use mod_time <- result.map(get_file_mod_time(from_path: path))

      #(filepath.directory_name(path), filepath.base_name(path), mod_time)
    })
    |> result.partition

  list.each(disk_file_errors, fn(e) {
    snag.layer(e, "Failed to get disk file entry") |> log_error
  })

  use db_file_entries <- result.map(file_cache.get_non_stale_files(conn))

  list.filter(disk_file_entries, fn(entry) {
    let #(file_dir, file_name, mod_time) = entry

    case
      list.find(db_file_entries, fn(db_entry) {
        db_entry.file_dir == file_dir
        && db_entry.file_name == file_name
        && db_entry.file_mod_time |> datetime.is_equal(to: mod_time)
      })
    {
      Ok(_) -> False
      Error(_) -> True
    }
  })
}

pub fn handle_fs_event(change: filespy.Change(a), state: WatcherActorState) {
  let #(_, processing_errors) =
    case change {
      filespy.Change(path:, events:) -> {
        list.map(events, fn(event) {
          case event {
            // TODO make all file system events go through this process so they
            // can't get too spammy. If a file is created then immediately
            // deleted, the actor should cancel those events out before they
            // get written to the db
            filespy.Created -> {
              io.println("Got created event for path " <> path)
              let file_dir = filepath.directory_name(path)
              let file_name = filepath.base_name(path)

              use mod_time <- result.try(get_file_mod_time(from_path: path))

              file_cache.add_new_file(
                state.conn,
                file_dir,
                file_name,
                mod_time,
                None,
              )
            }

            // TODO make all file system events go through the file mod 
            // watcher actor so they can't get too spammy
            filespy.Renamed -> {
              io.println("Got Renamed event for path " <> path)
              let file_dir = filepath.directory_name(path)
              let file_name = filepath.base_name(path)

              use mod_time <- result.try(get_file_mod_time(from_path: path))

              file_cache.add_new_file(
                state.conn,
                file_dir,
                file_name,
                mod_time,
                None,
              )
            }

            // Backing up based on mod events are delayed based on an interval
            filespy.Modified -> {
              process.send(state.file_mod_watcher, ModPath(path))
              Ok(Nil)
            }

            // TODO make all file system events go through this process so they
            // can't get too spammy
            filespy.Deleted -> {
              io.println("Got deleted event for path " <> path)
              let file_dir = filepath.directory_name(path)
              let file_name = filepath.base_name(path)

              file_cache.mark_file_as_stale(state.conn, file_dir, file_name)
            }

            _ -> Ok(Nil)
          }
        })
      }

      _ -> []
    }
    |> result.partition

  // Log any errors that occured while processing the files
  list.map(processing_errors, fn(processing_error) {
    snag.layer(processing_error, "Error processing file in watched directory")
    |> log_error
  })

  actor.continue(state)
}

pub type FileModWatcherActorState {
  FileModWatcherActorState(
    conn: process.Subject(file_cache.FileCacheRequest),
    paths: set.Set(String),
  )
}

pub type FileModWatcherMsg {
  ModPath(String)
  BackupMods
}

fn handle_mod_event(msg, state: FileModWatcherActorState) {
  let paths = case msg {
    ModPath(path) -> set.insert(state.paths, path)
    BackupMods -> {
      let #(_, processing_errors) =
        set.to_list(state.paths)
        |> list.map(fn(path) {
          io.println("Got created event for path " <> path)

          let file_dir = filepath.directory_name(path)
          let file_name = filepath.base_name(path)

          use mod_time <- result.try(get_file_mod_time(from_path: path))

          use _ <- result.try(file_cache.mark_file_as_stale(
            state.conn,
            file_dir,
            file_name,
          ))

          file_cache.add_new_file(
            state.conn,
            file_dir,
            file_name,
            mod_time,
            None,
          )
        })
        |> result.partition

      list.map(processing_errors, fn(e) {
        snag.layer(e, "Error processing modified file needing backup")
        |> log_error
      })

      set.new()
    }
  }

  actor.continue(FileModWatcherActorState(..state, paths:))
}

fn get_file_mod_time(from_path path) {
  simplifile.file_info(path)
  |> result.map(fn(file_info) {
    datetime.from_unix_utc(file_info.mtime_seconds)
  })
  |> snagx.from_error("Failed to get file mod time from " <> path)
}

fn hash_file(from_bits file) {
  use hash <- result.map(
    gsiphash.siphash_2_4(file, file_hash_key)
    |> snagx.from_error("Failed to hash file"),
  )

  hash |> int.to_base16 |> string.lowercase
}

pub fn start_backup_repeater(
  file_cache_conn file_cache_conn,
  backup_every_mins backup_every_mins,
  backup_base_path backup_base_path,
  backup_target_size backup_target_size,
) {
  repeatedly.call(backup_every_mins * 60_000, Nil, fn(_, n) {
    run_backup(
      file_cache_conn:,
      backup_target_size:,
      backup_base_path:,
      backup_number: n,
    )
    |> log_if_error("Failed to process backup")
  })
}

pub fn run_backup(
  file_cache_conn file_cache_conn,
  backup_target_size backup_target_size,
  backup_base_path backup_base_path,
  backup_number backup_number,
) {
  log("Running backup process #" <> int.to_string(backup_number))

  use files_needing_backup <- result.map(file_cache.get_files_needing_backup(
    file_cache_conn,
  ))

  let #(_, processing_errors) =
    list.map(files_needing_backup, fn(file_needing_backup) {
      let file_path =
        filepath.join(
          file_needing_backup.file_dir,
          file_needing_backup.file_name,
        )

      use processing_error <- result.try_recover({
        use file <- result.try(
          simplifile.read_bits(file_path)
          |> snagx.from_simplifile("Failed to read file at " <> file_path),
        )

        use hash <- result.try(hash_file(from_bits: file))

        use file_exists_in_backup <- result.try(
          file_cache.check_file_is_backed_up(file_cache_conn, hash),
        )

        use <- bool.guard(when: file_exists_in_backup, return: Ok(Nil))

        // Mark the file as processing
        use Nil <- result.try(file_cache.mark_file_as_processing(
          file_cache_conn,
          file_needing_backup.file_dir,
          file_needing_backup.file_name,
        ))

        use #(naive_datetime, offset) <- result.try(determine_date(
          for: file,
          at: file_path,
        ))

        use image <- result.try(image.from_bit_array(file))

        use faces <- result.try(detect_faces.detect_faces(in: file))

        let is_favorite = False

        let config = types.get_image_config(backup_target_size, is_favorite:)

        let user_metadata = ""

        use backup_image <- result.try(compress.image(
          image:,
          naive_datetime:,
          offset:,
          config:,
          original_file_path: file_path,
          is_favorite:,
          user_metadata:,
          faces:,
        ))

        let backup_file_path =
          get_backup_path(
            base_dir: backup_base_path,
            with: hash,
            targeting: backup_target_size,
          )

        let _ =
          filepath.directory_name(backup_file_path)
          |> simplifile.create_directory_all

        use Nil <- result.try(
          simplifile.write_bits(backup_image, to: backup_file_path)
          |> snagx.from_simplifile(
            "Failed to write backup file "
            <> backup_file_path
            <> " for "
            <> file_path,
          ),
        )

        file_cache.mark_file_as_backed_up(
          file_cache_conn,
          file_needing_backup.file_dir,
          file_needing_backup.file_name,
        )
      })

      processing_error
      |> snag.layer("Error processing file needing backup " <> file_path)
      |> log_error

      // If this failed, then mark the file as failed
      file_cache.mark_file_as_failed(
        file_cache_conn,
        file_needing_backup.file_dir,
        file_needing_backup.file_name,
      )
    })
    |> result.partition

  // Log any errors that occured while processing the files
  list.map(processing_errors, fn(processing_error) {
    snag.layer(processing_error, "Error processing file needing backup")
    |> log_error
  })

  Nil
}

pub fn get_backup_path(base_dir base_dir, with file_hash, targeting target_size) {
  string.to_graphemes(file_hash)
  |> list.take(3)
  |> list.append([file_hash])
  |> list.fold(from: base_dir, with: filepath.join)
  |> string.append(types.get_compressed_image_extension(target_size))
}

/// We have no way to determine if the file is a favorite or not in
/// this simple backup server
pub fn determine_date(for file_bits, at path) {
  // Try to get the date from the exif data first
  use _ <- result.try_recover({
    use exif <- result.try(get_exif(from_file: file_bits))
    use exif <- result.try(dict.get(exif, Exif))

    use naive_datetime_str <- result.try({
      use _ <- result.try_recover(dict.get(exif, Datetime))
      use _ <- result.try_recover(dict.get(exif, DatetimeDigitized))
      use _ <- result.try_recover(dict.get(exif, DatetimeDigitized))
      use _ <- result.try_recover(dict.get(exif, DatetimeOriginal))
      Error(Nil)
    })

    let offset_str =
      dict.get(exif, OffsetTime)
      |> result.try_recover(fn(_) { dict.get(exif, OffsetTimeDigitized) })
      |> result.try_recover(fn(_) { dict.get(exif, OffsetTimeOriginal) })
      |> result.map(Some)
      |> result.unwrap(None)

    use naive_datetime <- result.map(
      naive_datetime.parse(naive_datetime_str, "YYYY:MM:DD HH:mm:ss")
      |> result.nil_error,
    )

    let offset = case offset_str {
      Some(offset_str) ->
        offset.from_string(offset_str)
        |> result.map(Some)
        |> result.unwrap(None)
      None -> None
    }

    #(naive_datetime, offset)
  })

  // If there is no exif data, then try to get the date from the file path
  use _ <- result.try_recover({
    use #(date, time, offset) <- result.try(
      tempo.parse_any(path) |> result.nil_error,
    )

    case date, time {
      Some(date), Some(time) -> Ok(#(naive_datetime.new(date, time), offset))
      Some(date), None ->
        Ok(#(naive_datetime.new(date, time.literal("00:00")), offset))
      _, _ -> Error(Nil)
    }
  })

  // As a last resort, get the file date from the file system
  use _ <- result.try_recover({
    use file_info <- result.map(simplifile.file_info(path) |> result.nil_error)

    let naive_datetime =
      datetime.from_unix_utc(file_info.ctime_seconds)
      |> datetime.drop_offset

    #(naive_datetime, None)
  })

  snag.error("Failed to determine date for file " <> path)
}

type ExifKey {
  Exif
  Datetime
  DatetimeDigitized
  DatetimeOriginal
  OffsetTime
  OffsetTimeDigitized
  OffsetTimeOriginal
}

@external(erlang, "Elixir.Exexif", "exif_from_jpeg_buffer")
fn get_exif(
  from_file from_file: BitArray,
) -> Result(dict.Dict(ExifKey, dict.Dict(ExifKey, String)), Nil)

pub type CleanUpActorState {
  CleanUpActorState(
    backup_base_path: String,
    backup_target_size: types.TargetSize,
    delete_when_older_than: tempo.Duration,
  )
}

const one_day = 86_400_000

pub fn start_cleanup_repeater(
  file_cache_conn file_cache_conn,
  backup_base_path backup_base_path,
  backup_target_size backup_target_size,
  delete_when_older_than_days delete_when_older_than_days,
) {
  repeatedly.call(one_day, Nil, fn(_, n) {
    run_cleanup(
      file_cache_conn:,
      backup_base_path:,
      backup_target_size:,
      delete_when_older_than: duration.days(delete_when_older_than_days),
      cleanup_number: n,
    )
    |> log_if_error("Failed to process cleanup")
  })
}

pub fn run_cleanup(
  file_cache_conn file_cache_conn,
  backup_base_path backup_base_path,
  backup_target_size backup_target_size,
  delete_when_older_than delete_when_older_than,
  cleanup_number cleanup_number: Int,
) {
  log("Running cleanup process #" <> int.to_string(cleanup_number))

  use stale_files <- result.map(file_cache.get_stale_files(file_cache_conn))

  let #(_, processing_errors) =
    list.filter(stale_files, fn(stale_file) {
      stale_file.entry_time
      |> datetime.is_earlier(
        than: datetime.now_local()
        |> datetime.subtract(delete_when_older_than),
      )
    })
    |> list.map(fn(overly_stale_file) {
      use <- bool.guard(when: overly_stale_file.hash == None, return: Ok(Nil))
      let assert Some(hash) = overly_stale_file.hash

      let file_path =
        get_backup_path(
          base_dir: backup_base_path,
          with: hash,
          targeting: backup_target_size,
        )

      let _ = case overly_stale_file.status {
        file_cache.BackedUp -> {
          // If the file is not able to be deleted, then log it but continue
          use e <- result.try_recover(simplifile.delete(file_path))
          simplifile.describe_error(e)
          |> snag.new
          |> snag.layer("Unable to delete overly stale file " <> file_path)
          |> log_error
          Ok(Nil)
        }
        _ -> Ok(Nil)
      }

      file_cache.mark_file_as_deleted(
        file_cache_conn,
        overly_stale_file.file_dir,
        overly_stale_file.file_name,
      )
    })
    |> result.partition

  // Log any errors that occured while processing the files
  list.map(processing_errors, fn(processing_error) {
    snag.layer(processing_error, "Error cleaning up stale files")
    |> log_error
  })

  Nil
}

fn log(message) {
  io.println(message)
  let _ = simplifile.append("backup_server.txt", message <> "\n")
  Nil
}

fn log_error(snag) {
  io.println(snag.pretty_print(snag))
  let _ = simplifile.append("backup_server.txt", snag.line_print(snag) <> "\n")
  Nil
}

fn log_if_error(res, context) {
  case res {
    Error(e) -> {
      snag.layer(e, context) |> log_error
      Error(Nil)
    }
    Ok(v) -> Ok(v)
  }
}

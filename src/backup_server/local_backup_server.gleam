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
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import glenvy/env
import gsiphash
import repeatedly
import simplifile
import snag
import sqlight
import tempo
import tempo/datetime
import tempo/duration
import tempo/naive_datetime
import tempo/offset

pub const file_hash_key = <<"8027f33215eaaba5">>

pub type WatcherActorState {
  WatcherActorState(conn: sqlight.Connection)
}

pub fn init_watcher_actor(directory_paths) {
  use conn <- result.try(file_cache.connect_to_files_db(read_only: False))

  use _ <- result.map(
    list.map(directory_paths, fn(directory_path) {
      reconcile_dir_with_db(directory_path, conn)
    })
    |> result.all,
  )

  WatcherActorState(conn: conn)
}

/// Won't delete files from the backup that have been deleted since the
/// server was last running
pub fn reconcile_dir_with_db(directory_path, conn) {
  use _ <- result.try(file_cache.reset_processing_files(conn))

  use file_paths <- result.try(
    simplifile.get_files(directory_path)
    |> snagx.from_simplifile("Failed to get files in " <> directory_path),
  )

  let disk_file_entries =
    list.map(file_paths, fn(path) {
      use hash <- result.map(hash_file(from_path: path))

      #(filepath.directory_name(path), filepath.base_name(path), hash)
    })
    // Log these errors 
    |> result.values

  use db_file_entries <- result.try(file_cache.get_non_stale_files(conn))

  let new_disk_file_entries =
    list.filter(disk_file_entries, fn(entry) {
      let #(file_dir, file_name, hash) = entry

      case
        list.find(db_file_entries, fn(db_entry) {
          db_entry.file_dir == file_dir
          && db_entry.file_name == file_name
          && db_entry.hash == hash
        })
      {
        Ok(_) -> False
        Error(_) -> True
      }
    })

  use _ <- result.map(
    list.map(new_disk_file_entries, fn(entry) {
      let #(file_dir, file_name, hash) = entry

      // If a file is new, then mark all other files (previously) at the same
      // path as stale.
      use _ <- result.try(file_cache.mark_file_as_stale(
        conn,
        file_dir,
        file_name,
      ))

      // Once the stale files are marked, then add this new one at the path
      // with the new status.
      file_cache.add_new_file(conn, file_dir, file_name, hash)
    })
    |> result.all,
  )

  Nil
}

pub fn handle_fs_event(change: filespy.Change(String), state: WatcherActorState) {
  let processing_results = case change {
    filespy.Change(path:, events:) -> {
      let file_dir = filepath.directory_name(path)
      let file_name = filepath.base_name(path)

      list.map(events, fn(event) {
        case event {
          filespy.Created -> {
            use hash <- result.try(hash_file(from_path: path))

            file_cache.add_new_file(state.conn, file_dir, file_name, hash)
          }

          filespy.Modified -> {
            use hash <- result.try(hash_file(from_path: path))

            use file_entry <- result.try(file_cache.get_file_entry(
              state.conn,
              file_dir,
              file_name,
              hash,
            ))

            // If there is already an entry for this file then the contents
            // have not changed, so do nothing
            use <- bool.guard(when: option.is_some(file_entry), return: Ok(Nil))

            use _ <- result.try(file_cache.mark_file_as_stale(
              state.conn,
              file_dir,
              file_name,
            ))

            file_cache.add_new_file(state.conn, file_dir, file_name, hash)
          }

          filespy.Deleted -> {
            file_cache.mark_file_as_stale(state.conn, file_dir, file_name)
          }

          _ -> Ok(Nil)
        }
      })
    }

    _ -> []
  }

  // Log any errors that occured while processing the files
  processing_results
  |> list.filter_map(fn(res) {
    case res {
      Error(e) -> Ok(e)
      Ok(_) -> Error(Nil)
    }
  })
  |> list.map(fn(processing_error) {
    snag.layer(processing_error, "Error processing file in watched directory")
    |> snag.pretty_print
    |> io.println
  })

  actor.continue(state)
}

fn hash_file(from_path path) {
  use file <- result.try(
    simplifile.read_bits(path)
    |> snagx.from_simplifile("Failed to read file at " <> path),
  )

  use hash <- result.map(
    gsiphash.siphash_2_4(file, file_hash_key)
    |> snagx.from_error("Failed to hash file " <> path),
  )

  hash
}

pub type BackupActorState {
  BackupActorState(conn: sqlight.Connection, face_detection_uri: String)
}

pub fn start_backup_repeater(face_detection_uri, backup_every_mins) {
  use conn <- result.map(file_cache.connect_to_files_db(read_only: True))

  let state = BackupActorState(conn:, face_detection_uri:)

  repeatedly.call(backup_every_mins * 60_000, state, run_backup)
}

pub fn run_backup(state: BackupActorState, backup_number: Int) {
  use files_needing_backup <- result.map(file_cache.get_files_needing_backup(
    state.conn,
  ))

  let processing_results =
    list.map(files_needing_backup, fn(file_needing_backup) {
      let file_path =
        filepath.join(
          file_needing_backup.file_dir,
          file_needing_backup.file_name,
        )

      use target_size <- result.try(
        env.get("BACKUP_FILE_SIZE", types.string_to_target_size)
        |> snagx.from_error("Failed to get BACKUP_FILE_SIZE env var"),
      )

      use backup_base_path <- result.try(
        env.get_string("BACKUP_LOCATION")
        |> snagx.from_error("Failed to get BACKUP_LOCATION env var"),
      )

      use file <- result.try(
        simplifile.read_bits(file_path)
        |> snagx.from_simplifile("Failed to read file at " <> file_path),
      )

      use #(naive_datetime, offset) <- result.try(determine_date(
        for: file,
        at: file_path,
      ))

      use image <- result.try(image.from_bit_array(file))

      use faces <- result.try(detect_faces.detect_faces(in: file))

      let is_favorite = False

      let config = types.get_image_config(target_size:, is_favorite:)

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
          with: file_needing_backup.hash,
        )

      simplifile.write_bits(backup_image, to: backup_file_path)
      |> snagx.from_simplifile(
        "Failed to write backup file "
        <> backup_file_path
        <> " for "
        <> file_path,
      )
    })

  // Log any errors that occured while processing the files
  processing_results
  |> list.filter_map(fn(res) {
    case res {
      Error(e) -> Ok(e)
      Ok(_) -> Error(Nil)
    }
  })
  |> list.map(fn(processing_error) {
    snag.layer(processing_error, "Error processing file needing backup")
    |> snag.pretty_print
    |> io.println
  })
}

pub fn get_backup_path(base_dir base_dir, with file_hash) {
  let hash_str = file_hash |> int.to_string

  string.to_graphemes(hash_str)
  |> list.take(3)
  |> list.prepend(base_dir)
  |> list.append([hash_str])
  |> list.fold(from: "", with: filepath.join)
}

/// We have no way to determine if the file is a favorite or not in
/// this simple backup server
pub fn determine_date(for file, at path) {
  // Try to get the date from the exif data first
  use _ <- result.try_recover(
    {
      use exif <- result.try(get_exif(from_file: file))
      use exif <- result.try(dict.get(exif, Exif))

      use naive_datetime <- result.try({
        use _ <- result.try_recover(dict.get(exif, Datetime))
        use _ <- result.try_recover(dict.get(exif, DatetimeDigitized))
        use _ <- result.try_recover(dict.get(exif, DatetimeDigitized))
        use _ <- result.try_recover(dict.get(exif, DatetimeOriginal))
        Error(Nil)
      })

      let offset =
        dict.get(exif, OffsetTime)
        |> result.try_recover(fn(_) { dict.get(exif, OffsetTimeDigitized) })
        |> result.try_recover(fn(_) { dict.get(exif, OffsetTimeOriginal) })
        |> result.map(Some)
        |> result.unwrap(None)

      Ok(#(naive_datetime, offset))
    }
    |> result.try(fn(dts) {
      use naive_datetime <- result.map(
        naive_datetime.parse(dts.0, "YYYY:MM:DD HH:MM:SS") |> result.nil_error,
      )

      let offset = case dts.1 {
        Some(offset_str) ->
          offset.from_string(offset_str)
          |> result.map(Some)
          |> result.unwrap(None)
        None -> None
      }
      #(naive_datetime, offset)
    }),
  )

  // If there is no exif data, then try to get the date from the file path
  use _ <- result.try_recover({
    use #(date, time, offset) <- result.try(
      tempo.parse_any(path) |> result.nil_error,
    )

    case date, time {
      Some(date), Some(time) -> Ok(#(naive_datetime.new(date, time), offset))
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
    conn: sqlight.Connection,
    delete_when_older_than: tempo.Duration,
  )
}

const one_day = 86_400_000

pub fn start_cleanup_repeater(delete_when_older_than_days) {
  use conn <- result.map(file_cache.connect_to_files_db(read_only: True))

  let state =
    CleanUpActorState(
      conn:,
      delete_when_older_than: duration.days(delete_when_older_than_days),
    )

  repeatedly.call(one_day, state, run_cleanup)
}

pub fn run_cleanup(state: CleanUpActorState, cleanup_number: Int) {
  use stale_files <- result.map(file_cache.get_stale_files(state.conn))

  let processing_results =
    list.filter(stale_files, fn(stale_file) {
      stale_file.entry_mod_time
      |> datetime.is_earlier(
        than: datetime.now_local()
        |> datetime.subtract(state.delete_when_older_than),
      )
    })
    |> list.map(fn(overly_stale_file) {
      let file_path =
        filepath.join(overly_stale_file.file_dir, overly_stale_file.file_name)

      simplifile.delete(file_path)
      |> snagx.from_simplifile(
        "Unable to delete overly stale file " <> file_path,
      )
    })

  // Log any errors that occured while processing the files
  processing_results
  |> list.filter_map(fn(res) {
    case res {
      Error(e) -> Ok(e)
      Ok(_) -> Error(Nil)
    }
  })
  |> list.map(fn(processing_error) {
    snag.layer(processing_error, "Error cleaning up stale files")
    |> snag.pretty_print
    |> io.println
  })
}

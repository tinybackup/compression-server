import backup_server/file_cache
import ext/snagx
import filepath
import filespy
import gleam/bool
import gleam/io
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import gsiphash
import repeatedly
import simplifile
import snag
import sqlight

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
  use file_paths <- result.try(
    simplifile.get_files(directory_path)
    |> snagx.from_error("Failed to get files in " <> directory_path),
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
    |> snagx.from_error("Failed to read file at " <> path),
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

pub fn start_backup_repeater(face_detection_uri) {
  use conn <- result.map(file_cache.connect_to_files_db(read_only: True))

  let state = BackupActorState(conn:, face_detection_uri:)

  todo
}

pub fn run_backup(state: BackupActorState, backup_number: Int) {
  todo
}

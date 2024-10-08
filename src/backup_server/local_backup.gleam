import backup_server/file_cache
import ext/snagx
import filespy
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gsiphash
import simplifile
import snag
import sqlight

pub const file_hash_key = <<"8027f33215eaaba5">>

pub type BackupActorState {
  BackupActorState(conn: sqlight.Connection)
}

pub fn init_backup_actor() {
  use conn <- result.try(file_cache.connect_to_files_db())

  use _ <- result.map(reconcile_dir_with_db("./src", conn))

  BackupActorState(conn: conn)
}

pub fn reconcile_dir_with_db(directory_path, conn) {
  use file_paths <- result.try(
    simplifile.get_files(directory_path)
    |> snagx.from_error("Failed to get files in " <> directory_path),
  )

  let disk_file_entries =
    list.map(file_paths, fn(path) {
      use hash <- result.map(hash_file(from_path: path))
      #(path, hash)
    })
    // Log these errors 
    |> result.values

  use db_file_entries <- result.try(file_cache.get_all_db_files(conn))

  let new_disk_file_entries =
    list.filter(disk_file_entries, fn(entry) {
      let #(file_path, hash) = entry
      case
        list.find(db_file_entries, fn(db_entry) {
          db_entry.file_path == file_path && db_entry.hash == hash
        })
      {
        Ok(_) -> False
        Error(_) -> True
      }
    })

  use _ <- result.map(
    list.map(new_disk_file_entries, fn(entry) {
      let #(file_path, hash) = entry

      // If a file is new, then marke all other files (previously) at the same
      // path as stale.
      use _ <- result.try(file_cache.mark_file_as_stale(conn, file_path))
      // Once the stale files are marked, then add this new one at the path
      // with the new status.
      file_cache.add_new_file(conn, file_path, hash)
    })
    |> result.all,
  )

  Nil
}

pub fn handle_fs_event(change: filespy.Change(String), state: BackupActorState) {
  let processing_results = case change {
    filespy.Change(path:, events:) -> {
      list.map(events, fn(event) {
        case event {
          filespy.Created -> {
            use hash <- result.try(hash_file(from_path: path))

            file_cache.add_new_file(state.conn, path, hash)
          }

          filespy.Modified -> {
            use hash <- result.try(hash_file(from_path: path))

            use _ <- result.try(file_cache.mark_file_as_stale(state.conn, path))

            file_cache.add_new_file(state.conn, path, hash)
          }

          filespy.Deleted -> {
            file_cache.mark_file_as_stale(state.conn, path)
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

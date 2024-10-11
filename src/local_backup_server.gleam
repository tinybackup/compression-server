import backup_server/backup
import backup_server/file_cache
import compression_server/types
import ext/snagx
import filepath
import filespy
import gleam/bool
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/set
import repeatedly
import simplifile
import snag
import tempo
import tempo/datetime
import tempo/duration

pub fn main() {
  case run() {
    Ok(_) -> io.println("Exiting local backup server gracefully")
    Error(e) ->
      snag.layer(e, "Failed to start local backup server")
      |> snag.pretty_print
      |> io.println
  }
}

fn run() {
  use env <- result.try(backup.init_env())

  let #(
    backup_directories,
    backup_base_path,
    backup_target_size,
    backup_mod_every_mins,
    file_cache_conn,
  ) = env

  use Nil <- result.try(file_cache.reset_processing_files(file_cache_conn))

  use watcher_init_state <- result.try(init_watcher_actor(
    file_cache_conn,
    backup_directories,
    backup_mod_every_mins,
  ))

  use _ <- result.map(
    filespy.new()
    |> filespy.add_dirs(backup_directories)
    |> filespy.set_initial_state(watcher_init_state)
    |> filespy.set_actor_handler(handle_fs_event)
    |> filespy.start
    |> snagx.from_error("Failed to start file system watcher"),
  )

  start_backup_repeater(
    file_cache_conn:,
    backup_every_mins: 1,
    backup_base_path:,
    backup_target_size:,
  )

  start_cleanup_repeater(
    file_cache_conn:,
    backup_base_path:,
    backup_target_size:,
    delete_when_older_than_days: 7,
  )

  process.sleep_forever()
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
    backup.get_new_disk_files(directory_path, conn)
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
      file_cache.add_new_file(conn, file_dir, file_name, mod_time)
    })
    |> result.all
    |> snag.context("Failed to add new files to db"),
  )

  io.println("Reconciled directories with db")
  Nil
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

              use mod_time <- result.try(backup.get_file_mod_time(
                from_path: path,
              ))

              file_cache.add_new_file(state.conn, file_dir, file_name, mod_time)
            }

            // TODO make all file system events go through the file mod 
            // watcher actor so they can't get too spammy
            filespy.Renamed -> {
              io.println("Got Renamed event for path " <> path)
              let file_dir = filepath.directory_name(path)
              let file_name = filepath.base_name(path)

              use mod_time <- result.try(backup.get_file_mod_time(
                from_path: path,
              ))

              file_cache.add_new_file(state.conn, file_dir, file_name, mod_time)
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
    |> backup.log_error
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

          use mod_time <- result.try(backup.get_file_mod_time(from_path: path))

          use _ <- result.try(file_cache.mark_file_as_stale(
            state.conn,
            file_dir,
            file_name,
          ))

          file_cache.add_new_file(state.conn, file_dir, file_name, mod_time)
        })
        |> result.partition

      list.map(processing_errors, fn(e) {
        snag.layer(e, "Error processing modified file needing backup")
        |> backup.log_error
      })

      set.new()
    }
  }

  actor.continue(FileModWatcherActorState(..state, paths:))
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
    |> backup.log_if_error("Failed to process backup")
  })
}

pub fn run_backup(
  file_cache_conn file_cache_conn,
  backup_target_size backup_target_size,
  backup_base_path backup_base_path,
  backup_number backup_number,
) {
  backup.log("Running backup process #" <> int.to_string(backup_number))

  use files_needing_backup <- result.map(file_cache.get_files_needing_backup(
    file_cache_conn,
  ))

  let #(_, processing_errors) =
    list.map(files_needing_backup, fn(entry_needding_backup) {
      backup.backup_file(
        file_cache_conn,
        backup_base_path,
        backup_target_size,
        entry_needding_backup.file_dir,
        entry_needding_backup.file_name,
      )
    })
    |> result.partition

  // Log any errors that occured while processing the files
  list.map(processing_errors, fn(processing_error) {
    snag.layer(processing_error, "Error processing file needing backup")
    |> backup.log_error
  })

  Nil
}

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
    |> backup.log_if_error("Failed to process cleanup")
  })
}

pub fn run_cleanup(
  file_cache_conn file_cache_conn,
  backup_base_path backup_base_path,
  backup_target_size backup_target_size,
  delete_when_older_than delete_when_older_than,
  cleanup_number cleanup_number: Int,
) {
  backup.log("Running cleanup process #" <> int.to_string(cleanup_number))

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
        backup.get_backup_path(
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
          |> backup.log_error
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
    |> backup.log_error
  })

  Nil
}

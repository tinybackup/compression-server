import backup_server/file_cache
import backup_server/local_server
import compression_server/types
import ext/snagx
import filespy
import gleam/erlang/process
import gleam/io
import gleam/result
import glenvy/env
import snag

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
  use env <- result.try(local_server.init_env())

  let #(
    backup_directories,
    backup_base_path,
    backup_mod_every_mins,
    file_cache_conn,
  ) = env

  use Nil <- result.try(file_cache.reset_processing_files(file_cache_conn))

  use watcher_init_state <- result.try(local_server.init_watcher_actor(
    file_cache_conn,
    backup_directories,
    backup_mod_every_mins,
  ))

  use _ <- result.try(
    filespy.new()
    |> filespy.add_dirs(backup_directories)
    |> filespy.set_initial_state(watcher_init_state)
    |> filespy.set_actor_handler(local_server.handle_fs_event)
    |> filespy.start
    |> snagx.from_error("Failed to start file system watcher"),
  )

  use backup_target_size <- result.map(
    env.get("BACKUP_FILE_SIZE", types.string_to_target_size)
    |> snagx.from_error("Failed to get BACKUP_FILE_SIZE env var"),
  )

  local_server.start_backup_repeater(
    file_cache_conn:,
    backup_every_mins: 1,
    backup_base_path:,
    backup_target_size:,
  )

  local_server.start_cleanup_repeater(
    file_cache_conn:,
    backup_base_path:,
    backup_target_size:,
    delete_when_older_than_days: 7,
  )

  process.sleep_forever()
}

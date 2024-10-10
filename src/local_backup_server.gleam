import backup_server/file_cache
import backup_server/local_server
import compression_server/types
import ext/snagx
import filespy
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import glenvy/dotenv
import glenvy/env
import simplifile
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

  use file_cache_conn <- result.try(
    file_cache.start(at: backup_base_path)
    |> snagx.from_error("Failed to start file cache"),
  )

  use Nil <- result.try(file_cache.reset_processing_files(file_cache_conn))

  use watcher_init_state <- result.try(local_server.init_watcher_actor(
    file_cache_conn,
    backup_directories,
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
    file_cache_conn,
    backup_every_mins: 1,
    backup_base_path:,
    backup_target_size:,
  )

  local_server.start_cleanup_repeater(
    file_cache_conn,
    delete_when_older_than_days: 7,
  )

  process.sleep_forever()
}

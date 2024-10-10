import backup_server/local_server
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
  use _ <- result.try(dotenv.load() |> snagx.from_error("Failed to load .env"))

  use backup_directories <- result.try({
    use dirs <- result.map(
      env.get_string("INPUT_FILE_LOCATIONS")
      |> snagx.from_error("Failed to get INPUT_FILE_LOCATIONS env var"),
    )
    string.split(dirs, ",")
  })

  list.each(backup_directories, fn(dir) {
    io.println("Creating directory " <> dir)
    simplifile.create_directory_all(dir)
  })

  // todo reset processing files

  use watcher_init_state <- result.try(local_server.init_watcher_actor(
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

  use _ <- result.try(
    local_server.start_backup_repeater(1)
    |> snagx.from_error("Failed to start backup repeater"),
  )

  use _ <- result.map(
    local_server.start_cleanup_repeater(7)
    |> snagx.from_error("Failed to start cleanup repeater"),
  )

  process.sleep_forever()
}

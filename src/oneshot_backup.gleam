import backup_server/backup
import backup_server/file_cache
import gleam/io
import gleam/list
import gleam/result
import snag

pub fn main() {
  case run() {
    Ok(_) -> io.println("Completed oneshot backup")
    Error(e) ->
      snag.layer(e, "Failed to run oneshot backup")
      |> snag.pretty_print
      |> io.println
  }
}

pub fn run() {
  use env <- result.try(backup.init_env())

  let #(
    backup_directories,
    backup_base_path,
    backup_target_size,
    _,
    file_cache_conn,
  ) = env

  use new_files <- result.try(
    list.map(backup_directories, backup.get_new_disk_files(_, file_cache_conn))
    |> result.all,
  )

  let new_files = list.flatten(new_files)

  list.map(new_files, fn(new_file) {
    let #(file_dir, file_name, file_mod_time) = new_file

    io.print("Backing up file " <> file_dir <> "/" <> file_name <> " ... ")

    let backup_res = {
      use Nil <- result.try(file_cache.add_new_file(
        file_cache_conn,
        file_dir,
        file_name,
        file_mod_time,
      ))

      backup.backup_file(
        file_cache_conn,
        backup_base_path,
        backup_target_size,
        file_dir,
        file_name,
      )
    }

    case backup_res {
      Ok(Nil) -> io.println("Done")
      Error(e) ->
        snag.layer(e, "Failed to backup file, ")
        |> snag.line_print
        |> io.println
    }
  })

  Ok(Nil)
}

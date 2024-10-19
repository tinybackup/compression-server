import backup_server/backup
import backup_server/file_cache
import filepath
import gleam/io
import gleam/list
import gleam/result
import simplifile
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

  use _ <- result.try(
    list.map(new_files, fn(new_file) {
      let #(file_dir, file_name, file_mod_time) = new_file

      file_cache.add_new_file(
        file_cache_conn,
        file_dir,
        file_name,
        file_mod_time,
      )
    })
    |> result.all
    |> snag.context("Failed to reconcile new files with db"),
  )

  use files_needing_backup <- result.map({
    use Nil <- result.try(file_cache.reset_processing_files(file_cache_conn))

    use files <- result.map(file_cache.get_files_needing_backup(file_cache_conn))

    list.filter(files, fn(entry) {
      let path = filepath.join(entry.file_dir, entry.file_name)
      case simplifile.is_file(path) {
        Error(_) -> {
          io.println("Failed to read file " <> path)
          False
        }
        Ok(False) -> False
        Ok(True) -> True
      }
    })
  })

  list.map(files_needing_backup, fn(entry) {
    let file_path = filepath.join(entry.file_dir, entry.file_name)

    io.print("Backing up file " <> file_path <> " ... ")

    let backup_res = {
      backup.backup_file(
        file_cache_conn,
        backup_base_path,
        backup_target_size,
        entry.file_dir,
        entry.file_name,
      )
    }

    case backup_res {
      Ok(Nil) -> io.println("Done")
      // This is never being hit bc the error is captured and logged in the 
      // backup_file body
      Error(e) ->
        snag.layer(e, "Failed to backup file \n")
        |> snag.line_print
        |> io.println
    }
  })

  Ok(Nil)
}

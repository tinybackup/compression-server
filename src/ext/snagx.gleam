import gleam/string
import simplifile
import snag

pub fn from_error(res, context) {
  case res {
    Ok(value) -> Ok(value)
    Error(e) -> string.inspect(e) |> snag.new |> snag.layer(context) |> Error
  }
}

pub fn from_simplifile(res, context) {
  case res {
    Ok(value) -> Ok(value)
    Error(e) ->
      simplifile.describe_error(e) |> snag.new |> snag.layer(context) |> Error
  }
}

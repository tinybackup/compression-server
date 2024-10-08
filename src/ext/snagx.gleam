import gleam/string
import snag

pub fn from_error(res, context) {
  case res {
    Ok(value) -> Ok(value)
    Error(e) -> string.inspect(e) |> snag.new |> snag.layer(context) |> Error
  }
}

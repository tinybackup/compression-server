import ansel/bounding_box
import ext/snagx
import gleam/bit_array
import gleam/dynamic
import gleam/http
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/result
import gleam/string
import glenvy/env
import snag
import tempo/datetime

/// Sends the image to the face detection server url set in the 
/// FACE_DETECTION_SERVER_URL environment variable. 
pub fn detect_faces(in image: BitArray) {
  let boundary =
    datetime.now_utc() |> datetime.to_unix_milli_utc |> int.to_string
  let boundary_bits = boundary |> bit_array.from_string

  use face_detection_server_url <- result.try(
    env.get_string("FACE_DETECTION_SERVER_URL")
    |> snagx.from_error("Failed to get FACE_DETECTION_SERVER_URL env var"),
  )

  use base_req <- result.try(
    request.to(face_detection_server_url)
    |> snagx.from_error(
      "Failed to create base request from face detection server url"
      <> face_detection_server_url,
    ),
  )

  let body =
    bit_array.concat([
      <<"--">>,
      boundary_bits,
      <<"\r\n">>,
      <<
        "Content-Disposition: form-data; name=\"image\"; filename=\"file\"\r\n",
      >>,
      <<"Content-Type: application/octet-stream\r\n\r\n">>,
      image,
      <<"\r\n">>,
      <<"--">>,
      boundary_bits,
      <<"--\r\n">>,
    ])

  use resp <- result.try(
    base_req
    |> request.set_body(body)
    |> request.set_header(
      "content-type",
      "multipart/form-data; boundary=" <> boundary,
    )
    |> request.set_method(http.Post)
    |> httpc.send_bits
    |> snagx.from_error("Failed to send face detection request"),
  )

  use res <- result.try(
    json.decode_bits(resp.body, face_detection_results_decoder)
    |> snagx.from_error(
      "Failed to decode face detection with a status of "
      <> int.to_string(resp.status)
      <> " and a body of: \""
      <> {
        bit_array.to_string(resp.body)
        |> result.map(string.replace(_, "\n", ""))
        |> result.lazy_unwrap(fn() {
          string.inspect(resp.body) |> string.replace("\n", "")
        })
      }
      <> "\"",
    ),
  )

  list.map(res.face_bounds, fn(bounds) {
    case bounds.ltwh |> string.split(",") |> list.map(int.parse) {
      [Ok(l), Ok(t), Ok(w), Ok(h)] -> bounding_box.ltwh(l, t, w, h)

      _ ->
        snag.error(
          "Unable to parse face detection bounds from "
          <> string.inspect(res.face_bounds),
        )
    }
  })
  |> result.all
}

type FaceDetectionResult {
  FaceDetectionResult(face_bounds: List(FaceDetectionBounds))
}

type FaceDetectionBounds {
  FaceDetectionBounds(ltwh: String)
}

fn face_detection_results_decoder(dy) {
  let decoder =
    dynamic.decode1(
      FaceDetectionResult,
      dynamic.field(
        "face_bounds",
        dynamic.list(dynamic.decode1(
          FaceDetectionBounds,
          dynamic.field("ltwh", dynamic.string),
        )),
      ),
    )

  decoder(dy)
}

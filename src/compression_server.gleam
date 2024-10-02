import ansel
import ansel/bounding_box
import gleam/io
import tempo

pub type TargetSize {
  Original
  Medium
  Small
  Tiny
}

pub type CompressionRequest {
  CompressionRequest(
    image: ansel.Image,
    date: tempo.Date,
    is_favorite: Bool,
    target_size: TargetSize,
    original_file_path: String,
    user_metadata: String,
    faces: List(bounding_box.BoundingBox),
  )
}

pub fn main() {
  io.println("Hello from compression_server!")
}

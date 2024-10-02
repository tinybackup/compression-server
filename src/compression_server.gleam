import ansel
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
  )
}

pub fn main() {
  io.println("Hello from compression_server!")
}

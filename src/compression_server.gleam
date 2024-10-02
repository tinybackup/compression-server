import ansel
import ansel/fixed_bounding_box
import gleam/io
import tempo

pub type TargetSize {
  Original
  Medium
  Small
  Tiny
}

pub type CompressionRequest {
  Image(
    image: ansel.Image,
    date: tempo.Date,
    is_favorite: Bool,
    target_size: TargetSize,
    original_file_path: String,
    user_metadata: String,
    faces: List(fixed_bounding_box.FixedBoundingBox),
  )
  Video
}

pub type ExtractedArea {
  ExtractedArea(
    area: BitArray,
    quality: Int,
    bounding_box: fixed_bounding_box.FixedBoundingBox,
  )
}

pub fn main() {
  io.println("Hello from compression_server!")
}

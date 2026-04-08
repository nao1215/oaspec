/// Supported content types for code generation.
pub type ContentType {
  ApplicationJson
  TextPlain
  MultipartFormData
  UnsupportedContentType(String)
}

/// Parse a content type string into a ContentType.
pub fn from_string(content_type: String) -> ContentType {
  case content_type {
    "application/json" -> ApplicationJson
    "text/plain" -> TextPlain
    "multipart/form-data" -> MultipartFormData
    other -> UnsupportedContentType(other)
  }
}

/// Convert a ContentType back to its string representation.
pub fn to_string(content_type: ContentType) -> String {
  case content_type {
    ApplicationJson -> "application/json"
    TextPlain -> "text/plain"
    MultipartFormData -> "multipart/form-data"
    UnsupportedContentType(s) -> s
  }
}

/// Check if a content type is currently supported for code generation.
/// Initially only application/json is supported. As we add features,
/// we expand this to include text/plain (Phase 1-3) and
/// multipart/form-data (Phase 2-2).
pub fn is_supported(content_type: ContentType) -> Bool {
  case content_type {
    ApplicationJson -> True
    TextPlain -> True
    MultipartFormData -> True
    _ -> False
  }
}

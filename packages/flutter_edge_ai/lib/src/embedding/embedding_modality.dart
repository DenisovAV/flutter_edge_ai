/// A kind of input an embedding model can turn into a vector.
///
/// Adding a value breaks exhaustive switches, which is deliberate: a new kind
/// of input is a decision every app that switches over this has to make. The
/// LiteRT-LM v0.18.0 runtime has no video input, so there is no `video` value.
enum EmbeddingModality {
  /// Text, prefixed by the request's `TaskType`.
  text,

  /// An encoded image file (see `EncodedMediaFormat`).
  image,

  /// An encoded audio file (see `EncodedMediaFormat`).
  audio,
}

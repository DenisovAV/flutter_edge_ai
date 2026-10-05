/// Public export of the web (LiteRT.js) `EmbeddingModel` — [WebEmbeddingModel]
/// — for the engine package that builds the web embedding backend
/// (`flutter_gemma_litertlm`'s `litert_embedding_backend_web.dart`).
///
/// A separate top-level library, not folded into `flutter_gemma_litertlm.dart`:
/// this file is reached only from `flutter_gemma_litertlm`'s own
/// `if (dart.library.ffi)` web-conditional arm, so it must never be imported
/// from a context that could also compile to native (the `js_interop` import
/// underneath never resolves there).
library;

export 'src/embedding/web/web_embedding_model.dart';
export 'src/embedding/web/web_runtime.dart';

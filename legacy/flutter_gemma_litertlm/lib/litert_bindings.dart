/// Public, native-only export of the LiteRt interpreter FFI bindings
/// (`LiteRtBindings`) for native-only leaves that need to import the
/// concrete bindings from a file that is itself native-only (never reached
/// on web) — this package's own `src/embedding/litert_embedding_forward_pass.dart`
/// (as an intra-package import) and the capability package
/// `flutter_gemma_speech`.
///
/// Prefer this over `package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart`
/// in native-only files: that barrel's `LiteRtBindings` export is behind an
/// `if (dart.library.ffi)` conditional that `flutter analyze` resolves to the
/// empty web stub (single-library analysis, no compile-time environment),
/// which would make the symbol appear undefined during analysis even though
/// it resolves correctly at compile time on native platforms.
///
/// This library is unconditional — importing it from code that is also
/// reachable on web will fail to compile there. Native-only leaves should
/// import this directly instead of the implementation path
/// `package:flutter_gemma_litertlm/src/ffi/litert_bindings.dart`.
library;

export 'src/ffi/litert_bindings.dart';

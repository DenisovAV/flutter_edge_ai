// litertlm_dart's web internals that flutter_edge_ai_litertlm's web arm
// builds on: the engine created from a model stream, conversations with the
// adapter's resolved sampler, the conversation handle's close, and the page's
// `@litert-lm/core` embedding runtime. dart:js_interop: web only. For this
// repository's packages only: no compatibility promise, changed with any
// release. Apps use `package:litertlm_dart/litertlm_dart.dart`.
library;

export 'internal.dart';

export 'src/web/embedding_runtime_js.dart' show WindowLiteRtLmWebRuntime;
// The web Engine and EmbeddingEngine by their own library, for web-only
// files: the analyzer resolves the public library's conditional exports to
// the native ones.
export 'src/web/embedding_engine_web.dart' show EmbeddingEngine;
export 'src/web/engine_web.dart'
    show
        Engine,
        createConversationWithDefault,
        createWebEngine,
        webConversationMembers;
export 'src/web/litert_lm_js.dart'
    show
        JsLiteRtLmConversation,
        JsLiteRtLmEngine,
        awaitIfThenable,
        liteRtLmWebFetchedVersions,
        noteOtherWebRuntimeVersion,
        noteWebDeleteFailure;
export 'src/web/web_conversation_handle.dart' show WebConversationHandle;

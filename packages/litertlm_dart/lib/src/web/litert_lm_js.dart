// JS interop for the `@litert-lm/core` LLM API ([liteRtLmWebRuntimeVersion]),
// the surface the web `Engine` and its conversations drive.
//
// The page's module script must expose `Engine` on the global scope
// (`window.Engine = m.Engine`): `dart:js_interop` static interop resolves
// against the global, and the ESM export needs that explicit shim. It also
// sets `window.litertLmReady`, a Promise that settles once the module loaded
// (module scripts are deferred, so Dart can run first).
//
// API surface mirrored, as published (`dist/engine.d.ts`, `conversation.d.ts`,
// `conversation_config.d.ts`, `engine_settings.d.ts`):
//   const engine = await Engine.create({model, backend?, mainExecutorSettings?});
//   const convo = await engine.createConversation({sessionConfig, preface, ...});
//   const stream = convo.sendMessageStreaming(message); // ReadableStream<Message>
//   for await (const chunk of stream) ...                // {role, content: [...]}
//   convo.cancel(); await convo.delete(); await engine.delete();
//
// `sendMessageStreaming` returns a ReadableStream, which Chrome iterates as an
// async iterable. Dart has no async-iterator interop type, so the return is the
// opaque [JSObject] and is driven through `[Symbol.asyncIterator]().next()`
// (web_conversation_handle.dart).
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'web_runtime_version.dart';

/// `Backend` of `@litert-lm/core` (`wasm_binding_types.js`): `CPU: 3`,
/// `GPU: 4`, for the version the page pins ([liteRtLmWebRuntimeVersion]).
const liteRtLmWebBackendCpu = 3;
const liteRtLmWebBackendGpu = 4;

/// `Backend.GPU_ARTISAN`: what `engine.settings.backend` reports for a web
/// export such as `gemma-4-E2B-it-web.litertlm` on the GPU (0.18.0 and
/// 0.19.0, measured 2026-11-23): the same WebGPU, through the runtime's
/// legacy executor. 0.18.0 refuses such a model when asked for `backend: GPU`
/// ("Unsupported backend: 2"), so the GPU is asked for by leaving `backend`
/// out, the runtime's default.
const liteRtLmWebBackendGpuArtisan = 2;

/// What the page's `Engine` (or `EmbeddingEngine`) constructor lacks of what
/// this release calls ([members] on its prototype, `create` on itself); empty
/// when it has everything. A page that pins another `@litert-lm/core` than
/// [liteRtLmWebRuntimeVersion] is accepted as long as nothing is missing, so
/// moving the pin takes only the constant.
List<String> liteRtLmWebRuntimeMissing(
  JSObject constructor,
  List<String> members,
) {
  final prototype = constructor['prototype'];
  return [
    if (!(constructor['create']?.typeofEquals('function') ?? false)) 'create',
    for (final member in members)
      if (prototype == null ||
          !((prototype as JSObject)[member]?.typeofEquals('function') ?? false))
        member,
  ];
}

/// Awaits [result] when it is a thenable: `delete()` is a Promise in the
/// typings of 0.18.0 and 0.19.0, but nothing here relies on it.
Future<void> awaitIfThenable(JSAny? result) async {
  if (result != null &&
      result.isA<JSObject>() &&
      ((result as JSObject)['then']?.typeofEquals('function') ?? false)) {
    await (result as JSPromise<JSAny?>).toDart;
  }
}

/// `@JS('Engine')` makes the static `create` resolve against
/// `globalThis.Engine.create` (where the page's `window.Engine = m.Engine`
/// shim puts it) instead of the Dart-side type name.
@JS('Engine')
extension type JsLiteRtLmEngine._(JSObject _) implements JSObject {
  /// `Engine.create(engineSettings)`: `{model, backend?,
  /// mainExecutorSettings?: {maxNumTokens?}}`. `model` is a URL string, a
  /// `Blob` or a `ReadableStream<Uint8Array>`.
  external static JSPromise<JsLiteRtLmEngine> create(JSObject settings);

  /// What the engine resolved: `{backend, mainExecutorSettings: {maxNumTokens,
  /// ...}, ...}`.
  external JSObject? get settings;

  external JSPromise<JsLiteRtLmConversation> createConversation(
    JSObject config,
  );

  /// Frees the engine; a Promise in the published typings (await it with
  /// [awaitIfThenable]).
  external JSAny? delete();
}

extension type JsLiteRtLmConversation._(JSObject _) implements JSObject {
  /// A `ReadableStream` of `{role, content: [{type, text}, ...], ...}` chunks.
  /// [message] is a `string` (a user message of that text) or a `Message`
  /// object.
  external JSObject sendMessageStreaming(JSAny message);

  /// Asks the generation in flight to stop. The stream then rejects with
  /// "Task cancelled", and so does every later send on this conversation
  /// (0.18.0 and 0.19.0, measured 2026-11-23): a stopped conversation is
  /// replaced by one rebuilt from [getHistory].
  external void cancel();

  /// The conversation's messages: its completed exchanges (a cancelled turn
  /// is not in it).
  external JSPromise<JSArray<JSObject>> getHistory();

  /// Frees the conversation once its executor is free ([awaitIfThenable]).
  external JSAny? delete();
}

/// A JS AsyncIterator: `next()` is a Promise of `{value, done}`.
extension type JsAsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<JSObject> next();
}

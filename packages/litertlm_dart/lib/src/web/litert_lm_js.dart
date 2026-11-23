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

import 'web_runtime_version.dart';

/// `Backend` of `@litert-lm/core` (`wasm_binding_types.js`): `CPU: 3`,
/// `GPU: 4`, for the version the page pins ([liteRtLmWebRuntimeVersion]).
const liteRtLmWebBackendCpu = 3;
const liteRtLmWebBackendGpu = 4;

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

  /// `Promise<void>` since 0.19.0 (it waits for the engine's executor).
  external JSPromise<JSAny?> delete();
}

extension type JsLiteRtLmConversation._(JSObject _) implements JSObject {
  /// A `ReadableStream` of `{role, content: [{type, text}, ...], ...}` chunks.
  /// [message] is a `string` (a user message of that text) or a `Message`
  /// object.
  external JSObject sendMessageStreaming(JSAny message);

  /// Asks the generation in flight to stop.
  external void cancel();

  /// Frees the conversation once its executor is free.
  external JSPromise<JSAny?> delete();
}

/// `iter.next()` on a JS AsyncIterator: a Promise of `{value, done}`.
extension JsAsyncIterator on JSObject {
  external JSPromise<JSObject> next();
}

@JS()
library litert_lm_web;

import 'dart:js_interop';

/// JS interop for the upstream `@litert-lm/core` early-preview API
/// (`@litert-lm/core` 0.17.1 Web JavaScript surface).
///
/// The CDN script in `example/web/index.html` must expose `Engine` on
/// the global scope (`window.Engine`) because `dart:js_interop` static
/// interop resolves against the global. The `@litert-lm/core` ESM
/// export needs an explicit `window.Engine = Engine` shim in the
/// loader script.
///
/// API surface mirrored (see https://ai.google.dev/edge/litert-lm/js):
///   const engine = await Engine.create({ model: url });
///   const convo = await engine.createConversation({ preface: {messages: [...]} });
///   for await (const chunk of convo.sendMessageStreaming(text)) {
///     for (const item of chunk.content) if (item.type === 'text') ...
///   }
///   engine.delete();
///
/// `sendMessageStreaming` returns a JS AsyncIterator. Dart has no
/// first-class async iterator interop type, so the return is typed as
/// the opaque [JSObject] and driven via `iter.next()` from the Dart
/// side — see `litert_lm_web_inference.dart` for the pump loop.

/// `@JS('Engine')` makes the static `create` resolve against
/// `globalThis.Engine.create` (where the host page's
/// `window.Engine = m.Engine` shim puts it) instead of
/// `globalThis.LiteRtLmEngine.create` (the Dart-side class name) —
/// without this annotation Dart looks for the symbol under the type
/// name and fails with `Cannot read properties of undefined`.
@JS('Engine')
extension type LiteRtLmEngine._(JSObject _) implements JSObject {
  external static JSPromise<LiteRtLmEngine> create(LiteRtLmEngineOptions opts);

  external JSPromise<LiteRtLmConversation> createConversation(
    LiteRtLmConversationOptions opts,
  );

  external void delete();
}

extension type LiteRtLmConversation._(JSObject _) implements JSObject {
  /// Returns a JS AsyncIterable over `{content: [{type, text}, ...]}` chunks.
  /// Typed [JSObject] because `dart:js_interop` has no AsyncIterable type —
  /// we obtain the iterator via `[Symbol.asyncIterator]()` on the Dart side.
  ///
  /// Per the upstream TypeScript declarations [message] is
  /// `MessageLike | MessageLike[]` (= `string | Message | Array<...>`).
  /// We type as [JSAny] so callers can pass either `text.toJS` for the
  /// text-only path or a `jsify({role: 'user', content: [...] })` object
  /// for multimodal content.
  external JSObject sendMessageStreaming(JSAny message);

  /// Cancels an in-flight `sendMessageStreaming` generation upstream.
  /// Per the @litert-lm/core JS API.
  external void cancel();
}

/// Convenience extension to call `iter.next()` on a JS AsyncIterator
/// from Dart. Returns a Promise that resolves to `{value, done}`.
extension LiteRtLmAsyncIter on JSObject {
  external JSPromise<JSObject> next();
}

@JS()
@anonymous
@staticInterop
class LiteRtLmEngineOptions {
  external factory LiteRtLmEngineOptions({
    /// `String` (blob:/https: URL) OR a JS `ReadableStream` / `Blob`.
    /// Upstream `@litert-lm/core` accepts all three forms
    /// (`Engine.create({model: string | ReadableStream | Blob})`,
    /// per https://ai.google.dev/edge/litert-lm/js).
    ///
    /// Typed `JSAny` so Dart can pass either `url.toJS` (blob URL path)
    /// or a `ReadableStream` from `WebOPFSService.getStream` — required
    /// for >2 GB models that would otherwise trip Chrome's
    /// `ERR_BLOB_OUT_OF_MEMORY` blob-URL fetch limit.
    required JSAny model,
  });
}

@JS()
@anonymous
@staticInterop
class LiteRtLmConversationOptions {
  external factory LiteRtLmConversationOptions({
    /// `SessionConfig` from the upstream TS declarations:
    ///   { visionModalityEnabled?, audioModalityEnabled?, samplerParams?,
    ///     maxOutputTokens?, ... }
    /// Build with `jsify({...})`. Typed as opaque [JSObject] for forward
    /// compatibility.
    JSObject? sessionConfig,

    /// `Preface` from upstream TS:
    ///   { messages?: Message[], tools?: Tool[], extra_context?: {...} }
    /// `extra_context` is the same channel native FFI uses to enable
    /// Gemma 4 thinking mode (`{ "thinking": true }`).
    JSObject? preface,

    /// `filterChannelContentFromKvCache`: when thinking is enabled this
    /// strips the thinking channel content from the KV cache so it doesn't
    /// pollute follow-up turns. Mirrors the FFI `filter_channel_content_from_kv_cache`.
    bool? filterChannelContentFromKvCache,

    /// Whether the SDK prefills the preface immediately on init.
    bool? prefillPrefaceOnInit,

    /// Whether constrained decoding is enabled (used for native tool calling).
    bool? enableConstrainedDecoding,
  });
}

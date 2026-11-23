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
//   const engine =
//       await Engine.create({model, backend?, mainExecutorSettings?});
//   const convo =
//       await engine.createConversation({sessionConfig, preface, ...});
//   const stream = convo.sendMessageStreaming(message); // ReadableStream
//   for await (const chunk of stream) ...  // {role, content: [...]}
//   convo.cancel(); await convo.delete(); await engine.delete();
//
// `sendMessageStreaming` returns a ReadableStream, which Chrome iterates as an
// async iterable. Dart has no async-iterator interop type, so the return is the
// opaque [JSObject] and is driven through `[Symbol.asyncIterator]().next()`
// (web_conversation_handle.dart).
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../runtime/runtime_log.dart';
import 'web_runtime_version.dart';

/// `Backend` of `@litert-lm/core` (`wasm_binding_types.js`): `CPU: 3`,
/// `GPU: 4`, for the version the page pins ([liteRtLmWebRuntimeVersion]).
const liteRtLmWebBackendCpu = 3;
const liteRtLmWebBackendGpu = 4;

/// `Backend.GPU_ARTISAN`: what `engine.settings.backend` reports for a
/// Gemma 4 web or GPU export asked for the GPU (0.18.0 and 0.19.0, measured
/// 2026-11-23): the same WebGPU, through the runtime's legacy executor.
/// 0.19.0 takes `backend: GPU` (or GPU_ARTISAN) for it; 0.18.0 refused
/// `backend: GPU` ("Unsupported backend: 2").
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

/// The members [members] of a runtime object (an engine or a conversation)
/// that are not functions on it; empty when it has them all.
List<String> liteRtLmWebObjectMissing(JSObject object, List<String> members) =>
    [
      for (final member in members)
        if (!(object[member]?.typeofEquals('function') ?? false)) member,
    ];

/// Says [what] failed to free with `print`, once per page for each [what]
/// (an engine, a conversation, an embedding engine): release builds
/// show it, and memory the page never gets back is worth knowing about.
void noteWebDeleteFailure(String what, Object error) {
  if (!_deleteFailuresNoted.add(what)) return;
  // ignore: avoid_print
  print(
    '[litertlm_dart] WARNING: $what failed to free in $liteRtLmWebRuntime: '
    '$error. Its memory may stay in the page. Shown once per page for each '
    'kind of object.',
  );
}

/// The kinds of object whose failed delete was said.
final _deleteFailuresNoted = <String>{};

/// The `@litert-lm/core` versions the page fetched, read from the URLs of
/// its resources (`@litert-lm/core@X.Y.Z`): the runtime itself exports no
/// version. Empty when none was fetched by a versioned URL.
Set<String> liteRtLmWebFetchedVersions() {
  final performance = globalContext['performance'];
  if (performance == null || !performance.isA<JSObject>()) return <String>{};
  final JSArray<JSObject> entries;
  try {
    entries = (performance as JSObject).callMethod<JSArray<JSObject>>(
      'getEntriesByType'.toJS,
      'resource'.toJS,
    );
  } catch (e) {
    runtimeLog('[litertlm_dart/web] could not list the page\'s resources: $e');
    return <String>{};
  }
  return {
    for (final entry in entries.toDart)
      if (entry['name'] case final name? when name.isA<JSString>())
        if (_versioned.firstMatch((name as JSString).toDart) case final match?)
          match.group(1)!,
  };
}

final _versioned = RegExp(r'@litert-lm/core@(\d+\.\d+\.\d+)');

/// Says once, with `print`, when the page fetched another `@litert-lm/core`
/// than [liteRtLmWebRuntimeVersion]: one that has every member this release
/// calls still runs, but its behaviour is not the one measured (0.18.0
/// refuses the GPU export, "Unsupported backend: 2").
void noteOtherWebRuntimeVersion() {
  if (_versionNoted) return;
  final others = liteRtLmWebFetchedVersions()
    ..remove(liteRtLmWebRuntimeVersion);
  if (others.isEmpty) return;
  _versionNoted = true;
  // ignore: avoid_print
  print(
    '[litertlm_dart] WARNING: the page loaded @litert-lm/core '
    '${others.join(', ')}; this release is measured on '
    '$liteRtLmWebRuntimeVersion ($liteRtLmWebModuleUrl). Shown once per page.',
  );
}

bool _versionNoted = false;

/// The sentence a failed create ends with when the page fetched another
/// `@litert-lm/core` than [liteRtLmWebRuntimeVersion] by a versioned URL;
/// null when it did not, or when the runtime was self-hosted under a URL
/// without its version.
String? otherWebRuntimeVersionSentence() {
  final others = liteRtLmWebFetchedVersions()
    ..remove(liteRtLmWebRuntimeVersion);
  if (others.isEmpty) return null;
  return 'The page loaded @litert-lm/core ${others.join(', ')}; this release '
      'runs on $liteRtLmWebRuntimeVersion: import $liteRtLmWebModuleUrl in '
      'the page\'s module script.';
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

  /// Asks the generation in flight to stop (`cancelProcess()`). Measured on
  /// 0.18.0 and 0.19.0 (2026-11-23, web_litertlm_runtime_probe_test.dart): a
  /// generation
  /// stopped before its end rejects with "Task cancelled", and so does every
  /// later send on this conversation, so it is replaced by one rebuilt from
  /// [getHistory]; with nothing in flight, or after the last chunk, the
  /// conversation keeps working.
  external void cancel();

  /// The conversation's completed exchanges, without its preface (0.18.0 and
  /// 0.19.0, measured 2026-11-23): a cancelled turn is not in it. A user
  /// message sent as a string comes back with its content as that string,
  /// and an image or audio part's bytes as `blob: {bytes: [...]}` (0.19.0).
  external JSPromise<JSArray<JSObject>> getHistory();

  /// The conversation's token count. It runs on the engine's executor mutex,
  /// as a generation does, so it resolves only once the generation in flight
  /// has left the module: a stream that rejected may still be inside it
  /// (0.18.0 and 0.19.0 reject from the chunk callback, before
  /// `waitUntilDone`).
  external JSPromise<JSNumber> getTokenCount();

  /// Frees the conversation once its executor is free ([awaitIfThenable]).
  external JSAny? delete();
}

/// A JS AsyncIterator: `next()` is a Promise of `{value, done}`.
extension type JsAsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<JSObject> next();
}

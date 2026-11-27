// JS interop for the `@litert-lm/core` LLM API ([liteRtLmWebRuntimeVersion]),
// the surface the web `Engine` and its conversations drive.
//
// The page's module script hands over the whole module once, as
// `window.litertLm` ([liteRtLmWebModuleShim]), and sets `window.litertLmReady`,
// a Promise that settles once the module loaded (module scripts are deferred,
// so Dart can run first). [readLiteRtLmWebModule] reads it; each member this
// release calls (`Engine`, `EmbeddingEngine`, `Backend`) is read from it when
// it is called and refused by name when missing. The classes are reached
// through extension types over the objects read from the module, never
// through global `@JS` names, so dart2js and dart2wasm resolve them alike.
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
import 'web_backend_ids.dart';
import 'web_module_shim.dart';
import 'web_runtime_version.dart';

export 'web_backend_ids.dart'
    show LiteRtLmWebBackendEnumError, LiteRtLmWebBackendIds;
export 'web_module_shim.dart'
    show
        LiteRtLmWebModuleError,
        liteRtLmWebModuleShim,
        liteRtLmWebModuleShimLine;

/// Whether the page has a `window.litertLm` at all.
bool get hasLiteRtLmWebModule =>
    !(globalContext['litertLm']?.isUndefinedOrNull ?? true);

/// The page's `@litert-lm/core` module, as its module script hands it over
/// (`window.litertLm = m;`). Any object is accepted (a bundler may hand over
/// a plain object instead of a module namespace); its members are checked
/// when they are read. Throws [LiteRtLmWebModuleError] when it is not set,
/// naming the old lines to replace on a page that still sets
/// `window.Engine`, or when it is not an object.
LiteRtLmWebModule readLiteRtLmWebModule() {
  final module = globalContext['litertLm'];
  if (module == null || module.isUndefinedOrNull) {
    bool isFunction(String name) =>
        globalContext[name]?.typeofEquals('function') ?? false;
    throw LiteRtLmWebModuleError(
      liteRtLmWebModuleMissingMessage(
        legacyPage: isFunction('Engine') || isFunction('EmbeddingEngine'),
      ),
    );
  }
  if (!module.typeofEquals('object') && !module.typeofEquals('function')) {
    throw LiteRtLmWebModuleError(
      liteRtLmWebModuleMissingMessage(
        legacyPage: false,
        what: 'a value of type ${_typeOf(module)}',
      ),
    );
  }
  return module as LiteRtLmWebModule;
}

/// `window.litertLm`: the page's `@litert-lm/core` module.
extension type LiteRtLmWebModule._(JSObject _) implements JSObject {
  /// The module's `Engine` class. Throws [LiteRtLmWebModuleError] naming it
  /// when the module has none.
  JsLiteRtLmEngineClass get engineClass =>
      classNamed('Engine') as JsLiteRtLmEngineClass;

  /// The module's class [name] (`Engine`, `EmbeddingEngine`): a function.
  /// Throws [LiteRtLmWebModuleError] naming it when the module has none, or
  /// something else under that name.
  JSObject classNamed(String name) {
    final value = this[name];
    if (value == null || !value.typeofEquals('function')) {
      throw LiteRtLmWebModuleError(
        liteRtLmWebModuleMemberMessage(name, _describeMember(this, name)),
      );
    }
    return value as JSObject;
  }

  /// The module's `Backend` ids, read at each engine and embedding engine
  /// create, before anything is sent. Throws [LiteRtLmWebBackendEnumError]
  /// when the module has no `Backend`, or one that is not the enum.
  LiteRtLmWebBackendIds get backendIds =>
      LiteRtLmWebBackendIds.parse(_enumEntries(this['Backend']));
}

/// What [object]'s member [name] is, for a refusal: `a value of type
/// undefined` when it has none.
String _describeMember(JSObject object, String name) {
  final value = object[name];
  if (value == null) {
    return object.has(name) ? 'null' : 'a value of type undefined';
  }
  return 'a value of type ${_typeOf(value)}';
}

/// [value]'s own enumerable entries, a number as a [num] and anything else
/// as its `typeof`; a description of [value] when it is not a plain object,
/// null when it is not set.
Object? _enumEntries(JSAny? value) {
  if (value == null || value.isUndefinedOrNull) return null;
  if (!value.typeofEquals('object')) {
    return 'a value of type ${_typeOf(value)}';
  }
  final object = value as JSObject;
  final keys = (globalContext['Object']! as JSObject)
      .callMethod<JSArray<JSString>>('keys'.toJS, object)
      .toDart;
  return <String, Object?>{
    for (final key in keys)
      key.toDart: switch (object[key.toDart]) {
        final JSAny entry when entry.isA<JSNumber>() =>
          (entry as JSNumber).toDartDouble,
        final entry => entry == null ? 'undefined' : _typeOf(entry),
      },
  };
}

String _typeOf(JSAny value) => [
  'string',
  'number',
  'boolean',
  'bigint',
  'symbol',
  'function',
  'object',
].firstWhere(value.typeofEquals, orElse: () => 'unknown');

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
/// its resources (`@litert-lm/core@X.Y.Z`, with a prerelease such as
/// `0.21.0-nightly.20261125` whole): the runtime itself exports no version.
/// Empty when none was fetched by a versioned URL.
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

final _versioned = RegExp(
  r'@litert-lm/core@(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]*[0-9A-Za-z])?)',
);

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

/// The module's `Engine` class ([LiteRtLmWebModule.engineClass]).
extension type JsLiteRtLmEngineClass._(JSObject _) implements JSObject {
  /// `Engine.create(engineSettings)`: `{model, backend?,
  /// mainExecutorSettings?: {maxNumTokens?}}`. `model` is a URL string, a
  /// `Blob` or a `ReadableStream<Uint8Array>`.
  external JSPromise<JsLiteRtLmEngine> create(JSObject settings);
}

/// An `Engine` the runtime created.
extension type JsLiteRtLmEngine._(JSObject _) implements JSObject {
  /// What the engine resolved: `{backend, mainExecutorSettings: {maxNumTokens,
  /// ...}, ...}`.
  external JSObject? get settings;

  external JSPromise<JsLiteRtLmConversation> createConversation(
    JSObject config,
  );

  /// `Engine.createSession(sessionConfig?)` (0.20.0).
  external JSPromise<JsLiteRtLmSession> createSession(JSObject config);

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
  /// 0.18.0 and 0.19.0 (2026-11-23) and 0.20.0 (2026-11-25,
  /// web_litertlm_runtime_probe_test.dart): a generation
  /// stopped before its end rejects with "Task cancelled", and so does every
  /// later send on this conversation, so it is replaced by one rebuilt from
  /// [getHistory]; with nothing in flight, or after the last chunk, the
  /// conversation keeps working.
  external void cancel();

  /// The conversation's completed exchanges, without its preface (0.18.0 and
  /// 0.19.0, measured 2026-11-23; 0.20.0, 2026-11-25): a cancelled turn is
  /// not in it. A user message sent as a string comes back with its content
  /// as that string, and an image or audio part's bytes as
  /// `blob: {bytes: [...]}` (0.19.0 and 0.20.0).
  external JSPromise<JSArray<JSObject>> getHistory();

  /// The conversation's token count. It runs on the engine's executor mutex,
  /// as a generation does, so it resolves only once the generation in flight
  /// has left the module: a stream that rejected may still be inside it
  /// (0.18.0 and 0.19.0 reject from the chunk callback, before
  /// `waitUntilDone`).
  external JSPromise<JSNumber> getTokenCount();

  /// Frees the conversation once its executor is free ([awaitIfThenable]).
  external JSAny? delete();

  /// A copy of the conversation, independent of it from then on: its
  /// history and state (`Conversation.clone()`, 0.20.0).
  external JSPromise<JSObject> clone();
}

/// A `Session` the runtime created (0.20.0's session.d.ts): text prefill
/// and whole-reply decode, no streaming.
extension type JsLiteRtLmSession._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> runPrefill(JSArray<JSString> inputs);

  /// A `Responses`: `getTexts()` and `delete()`.
  external JSPromise<JsLiteRtLmResponses> runDecode();

  external void cancel();

  external JSPromise<JsLiteRtLmSession> clone();

  external JSAny? delete();
}

/// A session's `Responses`.
extension type JsLiteRtLmResponses._(JSObject _) implements JSObject {
  external JSArray<JSString> getTexts();

  external void delete();
}

/// A JS AsyncIterator: `next()` is a Promise of `{value, done}`.
extension type JsAsyncIterator._(JSObject _) implements JSObject {
  external JSPromise<JSObject> next();
}

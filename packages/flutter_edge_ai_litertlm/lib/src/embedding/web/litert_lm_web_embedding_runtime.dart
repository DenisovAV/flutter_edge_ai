/// The `dart:js_interop` side of the EmbeddingGemma 2 web pass:
/// [WindowLiteRtLmWebRuntime], the [LiteRtLmWebRuntime] the web backend hands
/// `LiteRtLmWebEmbeddingPass`, over `@litert-lm/core` 0.18.0's
/// `EmbeddingEngine` as the page exposes it:
///
/// ```html
/// <script type="module">
/// window.litertLmReady = (async () => {
///   const m = await import('https://cdn.jsdelivr.net/npm/@litert-lm/core@0.18.0/+esm');
///   window.Engine = m.Engine;
///   window.EmbeddingEngine = m.EmbeddingEngine;
///   return m.Engine;
/// })();
/// </script>
/// ```
///
/// The API used, as published in `@litert-lm/core` 0.18.0
/// (`dist/embedding_engine.d.ts`, `embedding_engine_settings.d.ts`,
/// `wasm_binding_types.js`):
///
/// ```js
/// EmbeddingEngine.create({model, backend, visionBackend?, maxInputLength,
///     minInputLength?, visionTokensPerImage?})      // Promise<EmbeddingEngine>
/// engine.computeEmbedding(input, {normalize, insertSpecialTokens,
///     inputOverflowStrategy})  // Promise<{embedding: number[], inputLength,
///                              //   truncatedLength?, numChunks}>
///   // input: a string, or {type: 'image', data: ArrayBuffer}
/// engine.delete()                                   // Promise<void>
/// ```
///
/// With `backend: GPU` (4, the backend the pass asks for) `create` sets up the
/// module's one WebGPU device itself, from
/// `navigator.gpu.requestAdapter({powerPreference: 'high-performance'})`;
/// [WindowLiteRtLmWebRuntime.webGpuSupport] asks the same question first, so
/// a page without WebGPU is refused before `create`.
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'litert_lm_web_embedding_pass.dart';

/// `Backend` in `@litert-lm/core` 0.18.0 (`wasm_binding_types.js`): `CPU: 3`,
/// `GPU: 4`. The page's module script pins that version.
int _backendValue(LiteRtLmWebBackend backend) => switch (backend) {
  LiteRtLmWebBackend.cpu => 3,
  LiteRtLmWebBackend.gpu => 4,
};

/// `InputOverflowStrategy` in `@litert-lm/core` 0.18.0: `CHUNK_AND_AVERAGE: 0`,
/// `TRUNCATE: 1`, `ERROR: 2`.
int _overflowValue(LiteRtLmWebOverflowStrategy strategy) => switch (strategy) {
  LiteRtLmWebOverflowStrategy.chunkAndAverage => 0,
  LiteRtLmWebOverflowStrategy.truncate => 1,
  LiteRtLmWebOverflowStrategy.error => 2,
};

/// `window.EmbeddingEngine`, resolved at the call: `@JS('EmbeddingEngine')`
/// makes the static `create` resolve against the global the page's shim sets.
@JS('EmbeddingEngine')
extension type _EmbeddingEngine._(JSObject _) implements JSObject {
  external static JSPromise<_EmbeddingEngine> create(JSObject settings);

  external JSPromise<_EmbeddingResponse> computeEmbedding(
    JSAny input,
    JSObject options,
  );

  external JSPromise<JSAny?> delete();
}

/// `EmbeddingResponse`. `truncatedLength` is undefined unless the engine cut
/// the input.
extension type _EmbeddingResponse._(JSObject _) implements JSObject {
  external JSArray<JSNumber>? get embedding;
  external JSNumber? get inputLength;
  external JSNumber? get truncatedLength;
  external JSNumber? get numChunks;
}

/// The [LiteRtLmWebRuntime] of the page: `window.litertLmReady` and
/// `window.EmbeddingEngine`.
final class WindowLiteRtLmWebRuntime implements LiteRtLmWebRuntime {
  const WindowLiteRtLmWebRuntime();

  static bool get _hasEmbeddingEngine =>
      globalContext['EmbeddingEngine'].typeofEquals('function');

  @override
  Future<LiteRtLmWebRuntimeState> ensureReady() async {
    if (_hasEmbeddingEngine) return LiteRtLmWebRuntimeState.ready;
    final ready = globalContext['litertLmReady'];
    if (ready == null || ready.isUndefinedOrNull) {
      return LiteRtLmWebRuntimeState.loaderMissing;
    }
    // Module scripts are deferred: the shim may still be importing the
    // module. A rejection (the CDN import failed) propagates.
    if (ready.typeofEquals('object') && (ready as JSObject).has('then')) {
      await (ready as JSPromise<JSAny?>).toDart;
    }
    return _hasEmbeddingEngine
        ? LiteRtLmWebRuntimeState.ready
        : LiteRtLmWebRuntimeState.embeddingEngineMissing;
  }

  /// `navigator.gpu.requestAdapter({powerPreference: 'high-performance'})`:
  /// the adapter `@litert-lm/core` 0.18.0 itself asks for before it creates
  /// a GPU engine (`createDefaultWebGpuDevice` in `litertlm_web.js`). The
  /// adapter is only looked at: the runtime requests its own device from its
  /// own adapter in `EmbeddingEngine.create`.
  @override
  Future<LiteRtLmWebGpuSupport> webGpuSupport() async {
    final navigator = globalContext['navigator'];
    if (navigator == null || navigator.isUndefinedOrNull) {
      return LiteRtLmWebGpuSupport.noWebGpu;
    }
    final gpu = (navigator as JSObject)['gpu'];
    if (gpu == null || gpu.isUndefinedOrNull) {
      return LiteRtLmWebGpuSupport.noWebGpu;
    }
    final options = JSObject()..['powerPreference'] = 'high-performance'.toJS;
    final adapter = await (gpu as JSObject)
        .callMethod<JSPromise<JSAny?>>('requestAdapter'.toJS, options)
        .toDart;
    return adapter == null || adapter.isUndefinedOrNull
        ? LiteRtLmWebGpuSupport.noAdapter
        : LiteRtLmWebGpuSupport.available;
  }

  @override
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings settings) async {
    final js = JSObject()
      ..['model'] = settings.modelUrl.toJS
      ..['backend'] = _backendValue(settings.backend).toJS
      ..['maxInputLength'] = settings.maxInputLength.toJS;
    // Absent, never null: the runtime tests `!== undefined`, and a null
    // visionBackend would ask for a tower with no backend.
    if (settings.visionBackend case final vision?) {
      js['visionBackend'] = _backendValue(vision).toJS;
    }
    if (settings.minInputLength case final min?) {
      js['minInputLength'] = min.toJS;
    }
    if (settings.visionTokensPerImage case final budget?) {
      js['visionTokensPerImage'] = budget.toJS;
    }
    final engine = await _EmbeddingEngine.create(js).toDart;
    return _WindowEngine(engine);
  }
}

final class _WindowEngine implements LiteRtLmWebEngine {
  _WindowEngine(this._engine);

  final _EmbeddingEngine _engine;

  @override
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  ) async {
    final JSAny part = switch (input) {
      LiteRtLmWebText(:final text) => text.toJS,
      // An ArrayBuffer of exactly the file — what the runtime itself makes
      // of a Blob before handing it to WebAssembly. A fresh copy: the input's
      // bytes are an unmodifiable view, whose buffer has no JS twin.
      LiteRtLmWebImage(:final bytes) =>
        JSObject()
          ..['type'] = 'image'.toJS
          ..['data'] = Uint8List.fromList(bytes).buffer.toJS,
    };
    final jsOptions = JSObject()
      ..['normalize'] = options.normalize.toJS
      ..['insertSpecialTokens'] = options.insertSpecialTokens.toJS
      ..['inputOverflowStrategy'] = _overflowValue(
        options.inputOverflowStrategy,
      ).toJS;
    final response = await _engine.computeEmbedding(part, jsOptions).toDart;
    final values =
        response.embedding ??
        (throw StateError('computeEmbedding returned no embedding'));
    return (
      embedding: [for (final v in values.toDart) v.toDartDouble],
      inputLength: _int(response.inputLength, 'inputLength'),
      truncatedLength: response.truncatedLength == null
          ? null
          : _int(response.truncatedLength, 'truncatedLength'),
      numChunks: response.numChunks == null
          ? 1
          : _int(response.numChunks, 'numChunks'),
    );
  }

  @override
  Future<void> delete() => _engine.delete().toDart;

  static int _int(JSNumber? value, String field) {
    if (value == null) {
      throw StateError('computeEmbedding returned no $field');
    }
    final number = value.toDartDouble;
    if (number != number.truncateToDouble()) {
      throw StateError('computeEmbedding returned a non-integer $field');
    }
    return number.toInt();
  }
}

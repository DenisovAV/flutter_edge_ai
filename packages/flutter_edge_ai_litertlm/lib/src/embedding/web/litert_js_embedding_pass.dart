// The web `.tflite` embedding pass (EmbeddingGemma 1) over the LiteRT.js
// bundle in this package's `web/litert_embeddings.js` — what the web
// `LiteRtEmbeddingBackend.describe` hands core. Core hosts it inline on the
// page, checks every request and closes it.
//
// Pure Dart: the bundle's window API arrives in the config as a
// [LiteRtJsBundle] (the `dart:js_interop` one from the web backend, a fake in
// the VM tests), so nothing here imports `dart:js_interop`.
//
// Bundle API v2 (R5 §7): the pass builds `taskType.prefix + text` with the one
// prefix function every engine uses, so all nine task types mean on web what
// they mean on native; the bundle tokenizes that one string as
// `[2, ...ids, 1]` — the native Dart tokenizer's ids — and reports the model's
// dimension and input length at load. An input longer than that comes back as
// `too_long` and is thrown as `EmbeddingInputTooLongException`, never
// truncated. A page whose copy of the bundle does not announce v2 is refused
// before anything loads.

import 'dart:async';

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_edge_ai/engine.dart';

import 'web_runtime.dart';

/// The `web/litert_embeddings.js` window API (bundle API v2), as the pass uses
/// it.
abstract interface class LiteRtJsBundle {
  /// Whether `web/litert_embeddings.js` is on the page at all — its window
  /// API exists. When it is not, no call below can do anything but throw.
  bool get isPresent;

  /// `liteRtEmbeddingsApiVersion`: [liteRtJsBundleApiVersion] for the bundle
  /// this package ships; null when the page's copy sets none (every bundle
  /// before v2).
  int? get apiVersion;

  /// `loadLiteRtEmbeddings`: fetches the tokenizer, then fetches and compiles
  /// the model, and reports what it read from the model — its output's last
  /// dimension and its input's sequence length. Page-global state.
  Future<({int dimension, int maxInputTokens})> load(
    String modelUrl,
    String tokenizerUrl,
    String wasmPath,
  );

  /// `embedLiteRtText`: embeds [prefixedText] exactly as given.
  Future<LiteRtJsEmbedResult> embed(String prefixedText);

  /// `cleanupLiteRtEmbeddings`: frees the model and the tokenizer.
  Future<void> dispose();
}

/// The window API version this package's `web/litert_embeddings.js`
/// implements, and the only one the pass accepts.
const liteRtJsBundleApiVersion = 2;

/// What `embedLiteRtText` answered.
sealed class LiteRtJsEmbedResult {
  const LiteRtJsEmbedResult();
}

/// `{status: 'ok', values}`: the model's output vector.
final class LiteRtJsVector extends LiteRtJsEmbedResult {
  const LiteRtJsVector(this.values);

  final List<double> values;
}

/// `{status: 'too_long', actualTokens, maxInputTokens}`: the ids — BOS and EOS
/// included — are longer than the model's input. Nothing ran.
final class LiteRtJsTooLong extends LiteRtJsEmbedResult {
  const LiteRtJsTooLong({
    required this.actualTokens,
    required this.maxInputTokens,
  });

  final int actualTokens;
  final int maxInputTokens;
}

/// What the web `LiteRtEmbeddingBackend.describe` hands core: the model and
/// tokenizer paths core registered for the active spec, the bundle, and how to
/// turn those paths into URLs the bundle can fetch.
///
/// Hosted inline, never sent across an isolate.
final class LiteRtJsEmbeddingConfig {
  const LiteRtJsEmbeddingConfig({
    required this.modelPath,
    required this.tokenizerPath,
    required this.bundle,
    required this.resolveUrl,
    required this.revokeUrl,
  });

  /// The paths core registered for the installed files — under
  /// `WebStorageMode.streaming` an `opfs://` path the bundle's `fetch()`
  /// cannot open.
  final String modelPath;
  final String tokenizerPath;

  final LiteRtJsBundle bundle;

  /// `resolveWebModelUrl`: `opfs://` → `blob:`, anything else unchanged.
  final Future<String> Function(String path) resolveUrl;

  /// `URL.revokeObjectURL`: releases a URL [resolveUrl] created. The pass
  /// owns those (the `blob:` URL of an `opfs://` path) and revokes them once
  /// the bundle has read them; a path it did not resolve from `opfs://` is
  /// never revoked.
  final void Function(String url) revokeUrl;
}

/// The descriptor factory.
EmbeddingPass buildLiteRtJsEmbeddingPass(LiteRtJsEmbeddingConfig config) =>
    LiteRtJsEmbeddingPass(config);

/// The engine tag in the errors this pass raises.
const liteRtJsEngine = 'LiteRT.js';

/// The LiteRT.js embedding pass. Text only.
final class LiteRtJsEmbeddingPass extends EmbeddingPass {
  LiteRtJsEmbeddingPass(this._config);

  final LiteRtJsEmbeddingConfig _config;

  LiteRtJsBundle get _bundle => _config.bundle;

  /// Where the page's LiteRT.js runtime was actually loaded from, if at all.
  /// Static because the runtime is one per page, not one per pass.
  static String? _loadedWasmPath;

  /// Every load and every dispose of the page's LiteRT.js embedding state, in
  /// the order they were CALLED, across all passes.
  ///
  /// That state is one per page (`tfliteModel`, `tokenizer` and
  /// `isInitialized` in litert_embeddings.js). Without a page-wide order, a
  /// pass still disposing and its replacement loading race: the old dispose
  /// can land after the new load and delete the state the new pass just
  /// loaded. Only the owner of that state can order the two.
  static Future<void> _pageLane = Future<void>.value();

  /// Runs [op] on the page lane. The lane advances on a gate of its own, so
  /// [op]'s failure still reaches whoever awaits it and never blocks the next
  /// op.
  static Future<T> _onPage<T>(Future<T> Function() op) {
    final previous = _pageLane;
    final gate = Completer<void>();
    _pageLane = gate.future;
    return previous.then((_) => op()).whenComplete(gate.complete);
  }

  /// Whether this pass's load reached the bundle — and its close must
  /// therefore dispose the page state, even when the load FAILED: the bundle
  /// loads the tokenizer before it compiles the model, so a failed compile
  /// leaves the tokenizer allocated, and the next load would overwrite it
  /// without freeing it. `cleanupLiteRtEmbeddings` checks each piece and is
  /// safe on partial state.
  bool _touchedPage = false;
  bool _closed = false;

  @override
  Future<EmbeddingPassInfo> load() => _onPage(() async {
    if (_closed) {
      throw StateError('LiteRtJsEmbeddingPass was closed before it loaded');
    }
    // Before anything is resolved or the page counts as touched: without the
    // bundle there is no page state, so the close behind this failure has
    // nothing to dispose — and must not call the missing cleanup, which core
    // would report as a native model that "may still be resident".
    if (!_bundle.isPresent) {
      throw const EmbeddingLoadException(
        'web/litert_embeddings.js is not loaded on this page. Copy '
        'packages/flutter_edge_ai_litertlm/web/litert_embeddings.js (and the '
        "three files it imports) into your app's web/ and add "
        '<script type="module" src="litert_embeddings.js"></script> to '
        'web/index.html.',
        engine: liteRtJsEngine,
      );
    }
    // Same reasoning: a stale copy is refused before it is touched. Its
    // functions would otherwise embed every task type but a document with the
    // query prompt and truncate long input without a word.
    _checkApiVersion(_bundle.apiVersion);
    // Configurable since 2.2.0; the old hardcoded '/wasm/' was served by
    // nothing, so this call always failed. See [LiteRtWebRuntime].
    final wasmPath = LiteRtWebRuntime.wasmPath;
    // The runtime is a page-level singleton behind a flag in
    // litert_embeddings.js: once it has loaded, a different prefix is
    // discarded there without a word. Say so here instead.
    final loadedFrom = _loadedWasmPath;
    if (loadedFrom != null && loadedFrom != wasmPath) {
      edgeAiLog(
        'LiteRtWebRuntime.wasmPath changed to $wasmPath after the runtime '
        'was loaded from $loadedFrom — the new value is ignored. Set it '
        'before the first embedder loads.',
      );
    }
    // Under WebStorageMode.streaming both are `opfs://`, which the bundle's
    // fetch() rejects: every LiteRT.js embedder failed to load there.
    final tokenizerUrl = await _config.resolveUrl(_config.tokenizerPath);
    final ({int dimension, int maxInputTokens}) model;
    try {
      final modelUrl = await _config.resolveUrl(_config.modelPath);
      try {
        _touchedPage = true;
        model = await _bundle.load(modelUrl, tokenizerUrl, wasmPath);
      } finally {
        // The bundle has read the model by now (or failed to).
        _releaseIfCreated(_config.modelPath, modelUrl);
      }
    } finally {
      _releaseIfCreated(_config.tokenizerPath, tokenizerUrl);
    }
    _loadedWasmPath ??= wasmPath;
    if (kDebugMode) edgeAiLog('LiteRT.js embeddings loaded');
    // Both read from the model by the bundle: the output's last dimension and
    // the input's sequence length, which the prefix, BOS and EOS count
    // towards.
    return EmbeddingPassInfo(
      dimension: model.dimension,
      maxInputTokens: model.maxInputTokens,
    );
  });

  static void _checkApiVersion(int? version) {
    if (version == liteRtJsBundleApiVersion) return;
    if (version == null || version < liteRtJsBundleApiVersion) {
      throw const EmbeddingLoadException(
        'web/litert_embeddings.js is older than flutter_edge_ai_litertlm '
        '1.13.0; copy packages/flutter_edge_ai_litertlm/web/'
        'litert_embeddings.js into your web/',
        engine: liteRtJsEngine,
      );
    }
    throw EmbeddingLoadException(
      'web/litert_embeddings.js implements bundle API v$version, newer than '
      'this flutter_edge_ai_litertlm (v$liteRtJsBundleApiVersion); copy the '
      'litert_embeddings.js of the flutter_edge_ai_litertlm version your app '
      'depends on into your web/',
      engine: liteRtJsEngine,
    );
  }

  /// Revokes [url] when this pass created it — the `blob:` URL of an
  /// `opfs://` [rawPath] — and never a URL core owns. Each holds a
  /// model-sized Blob until the page unloads otherwise.
  void _releaseIfCreated(String rawPath, String url) {
    if (rawPath.startsWith('opfs://')) _config.revokeUrl(url);
  }

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async {
    final text = input.text;
    if (text == null) {
      throw StateError('LiteRtJsEmbeddingPass embeds text only');
    }
    // The one prefix function, as on native; empty text is embedded too.
    final result = await _bundle.embed(taskType.prefix + text);
    return switch (result) {
      LiteRtJsVector(:final values) => values,
      LiteRtJsTooLong(:final actualTokens, :final maxInputTokens) =>
        throw EmbeddingInputTooLongException(
          'The input is $actualTokens tokens (task prefix, BOS and EOS '
          'included); this model takes at most $maxInputTokens. Split the '
          'text and embed the pieces.',
          maxInputTokens: maxInputTokens,
          actualTokens: actualTokens,
        ),
    };
  }

  @override
  Future<void> close() {
    if (_closed) return Future<void>.value();
    _closed = true;
    // Queued NOW: behind any load already on the lane — this pass's own
    // included, so that one is never leaked — and ahead of any load a
    // replacement starts after this call.
    return _onPage(() async {
      if (!_touchedPage) return;
      _touchedPage = false;
      await _bundle.dispose();
      if (kDebugMode) edgeAiLog('LiteRT.js embeddings disposed');
    });
  }
}

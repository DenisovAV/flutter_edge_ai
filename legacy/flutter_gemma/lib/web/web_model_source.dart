// Standalone public library: the shared web model-source resolution used by
// both the MediaPipe-web inference model (in core) and the litertlm-web
// inference model (extracted into `flutter_gemma_litertlm`). Both import this
// directly so neither has to be a `part of flutter_gemma_web.dart`.
import 'dart:js_interop';
import 'package:flutter_gemma/core/utils/gemma_log.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/infrastructure/web_download_service.dart';
// Conditional import: same pattern WebDownloadService uses so the opfsService
// field type matches statically (both sides of the resolver agree on the type).
import 'package:flutter_gemma/core/infrastructure/web_opfs_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_gemma/core/infrastructure/web_opfs_service.dart';
import 'package:flutter_gemma/core/model_management/constants/preferences_keys.dart';
import 'package:flutter_gemma/core/model_management/managers/web_model_manager.dart';

/// Result of resolving an active web model into a form an engine
/// (MediaPipe `LlmInference` OR `@litert-lm/core` `Engine`) can consume.
///
/// Both engines accept either a URL string (`blob:`/`https:`) or a JS
/// `ReadableStream` / `ReadableStreamDefaultReader`. This sealed type
/// encodes that choice once so engine-specific glue stays trivial.
sealed class WebModelSource {
  const WebModelSource();
}

/// `WebStorageMode.cacheApi` / `WebStorageMode.none` path. [url] is a
/// `blob:` URL produced by `WebCacheService` / `BlobUrlManager`, or an
/// `https:` URL when caching is disabled.
final class BlobUrlModelSource extends WebModelSource {
  const BlobUrlModelSource(this.url);
  final String url;
}

/// `WebStorageMode.streaming` + `opfs://<filename>` path. Carries the
/// [WebOPFSService] and the OPFS filename so each engine can ask for
/// the form it consumes — MediaPipe wants a
/// `ReadableStreamDefaultReader`, `@litert-lm/core` wants the raw
/// `ReadableStream`.
final class OpfsStreamModelSource extends WebModelSource {
  const OpfsStreamModelSource(this.opfsService, this.filename);
  final WebOPFSService opfsService;
  final String filename;

  /// `ReadableStreamDefaultReader` — used by MediaPipe's
  /// `LlmInferenceBaseOptions.modelAssetBuffer`.
  Future<JSAny> openReader() => opfsService.getStreamReader(filename);

  /// Raw `ReadableStream` — used by `@litert-lm/core`'s
  /// `Engine.create({model: <ReadableStream>})`.
  Future<JSAny> openStream() => opfsService.getStream(filename);
}

/// Resolves the active inference model from [WebModelManager] into the
/// correct [WebModelSource] subtype based on [ServiceRegistry]
/// `useStreamingStorage` and the resolved path prefix. This is the
/// single piece of code that decides blob-URL vs OPFS-stream — both
/// `WebInferenceModel` (MediaPipe) and `LiteRtLmWebInferenceModel`
/// (`@litert-lm/core`) consume it.
class WebModelSourceResolver {
  WebModelSourceResolver(this._modelManager);

  /// Builds a resolver backed by a fresh [WebModelManager], which rehydrates
  /// the active model from persisted prefs. Lets an engine package construct
  /// the resolver without a `FlutterGemmaWeb` instance.
  factory WebModelSourceResolver.forActiveModel() =>
      WebModelSourceResolver(WebModelManager());
  final WebModelManager _modelManager;

  /// Resolves the active inference model. Returns the source plus the
  /// installed LoRA path if any (only meaningful for MediaPipe; LiteRT-LM
  /// throws on `loraPath`).
  Future<({WebModelSource model, String? loraPath})>
  resolveActiveInferenceModel() async {
    // A resolver built via `forActiveModel()` holds a FRESH WebModelManager
    // whose active identity is rehydrated from prefs asynchronously. Without
    // this await, `activeInferenceModel` is read before the restore completes
    // and reports null even though a model was just installed ("No active
    // inference model set" on createChat). `ensureInitialized` is idempotent.
    await _modelManager.ensureInitialized();
    final active = _modelManager.activeInferenceModel;
    if (active == null) {
      throw StateError(
        'No active inference model set. Use FlutterGemma.installModel() first.',
      );
    }
    final paths = await _modelManager.getModelFilePaths(active);
    if (paths == null || paths.isEmpty) {
      throw StateError('Model file paths not found for active model.');
    }
    final raw = paths[PreferencesKeys.installedModelFileName];
    if (raw == null) {
      throw StateError('Model path not found in file paths.');
    }
    final lora = paths[PreferencesKeys.installedLoraFileName];
    final source = await _toSource(raw);
    return (model: source, loraPath: lora);
  }

  Future<WebModelSource> _toSource(String raw) async {
    final registry = ServiceRegistry.instance;
    if (registry.useStreamingStorage && raw.startsWith('opfs://')) {
      final filename = raw.substring('opfs://'.length);
      final downloadService = registry.downloadService;
      if (downloadService is! WebDownloadService) {
        throw StateError('Expected WebDownloadService for web platform.');
      }
      final opfs = downloadService.opfsService;
      if (opfs == null) {
        throw StateError(
          'OPFS service not available (streaming mode requires OPFS).',
        );
      }
      if (kDebugMode) {
        gemmaLog('[WebModelSourceResolver] OPFS stream source for: $filename');
      }
      return OpfsStreamModelSource(opfs, filename);
    }
    if (kDebugMode) {
      gemmaLog('[WebModelSourceResolver] Blob/HTTPS URL: $raw');
    }
    return BlobUrlModelSource(raw);
  }
}

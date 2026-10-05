// Resolves `opfs://<filename>` paths — what core registers for the active
// model under `WebStorageMode.streaming` (`WebDownloadService.registerUrl`,
// consumed by both engine-side `EmbeddingModel` construction paths in
// `flutter_gemma_web.dart`) — into a `blob:` URL that both `fetch()`
// (tokenizer.json) and `ort.InferenceSession.create()` (the model file) can
// actually load. Neither understands the OPFS-private `opfs://` scheme;
// passing it straight through leaves both calls unable to read the file.
//
// Mirrors the resolution core itself does for MediaPipe/LiteRT-LM inference
// models in `WebModelSourceResolver._toSource`
// (`package:flutter_gemma/web/web_model_source.dart`) — same
// `ServiceRegistry.instance.useStreamingStorage` + `WebDownloadService.opfsService`
// lookup — but produces a `blob:` URL instead of a raw `ReadableStream`
// since both consumers here want a URL, not a stream/reader.
//
// `WebStorageMode.cacheApi`/`.none` paths are already `blob:`/`https:` URLs
// (or a plain HTTPS URL when caching is off) and pass through unchanged.
import 'dart:js_interop';

import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/infrastructure/web_download_service.dart';

@JS('Response')
extension type _JSResponse._(JSObject _) implements JSObject {
  external factory _JSResponse(JSAny body);
  external JSPromise<JSAny> blob();
}

@JS('URL.createObjectURL')
external JSString _createObjectUrlJs(JSAny blob);

/// Resolves [rawPath] to a URL that `fetch()`/`ort.InferenceSession.create()`
/// can load. Non-`opfs://` paths pass through unchanged.
Future<String> resolveOnnxWebPath(String rawPath) async {
  if (!rawPath.startsWith('opfs://')) return rawPath;

  final registry = ServiceRegistry.instance;
  if (!registry.useStreamingStorage) {
    throw StateError(
      'Got an "opfs://" path ("$rawPath") but streaming storage is not '
      'enabled (webStorageMode != WebStorageMode.streaming).',
    );
  }
  final downloadService = registry.downloadService;
  if (downloadService is! WebDownloadService) {
    throw StateError(
      'Expected WebDownloadService to resolve "$rawPath" on web.',
    );
  }
  final opfs = downloadService.opfsService;
  if (opfs == null) {
    throw StateError(
      'OPFS service not available for "$rawPath" (streaming mode requires '
      'OPFS).',
    );
  }

  final filename = rawPath.substring('opfs://'.length);
  final stream = await opfs.getStream(filename);
  // `WebOPFSService.getStream` types as `Never` under the non-web analyzer
  // config (the `dart.library.js_interop` conditional-import stub) — same
  // false-positive the core `WebDownloadService` silences at its own
  // `opfsService!` call sites (`web_download_service.dart`). Real web builds
  // resolve the actual `Future<JSAny>` implementation.
  // ignore: dead_code
  final blob = await _JSResponse(stream).blob().toDart;
  return _createObjectUrlJs(blob).toDart;
}

// Resolves a web model path that core registered for an installed file into a
// URL `fetch()` (or an ONNX Runtime Web / Transformers.js loader) can open.
//
// Under `WebStorageMode.streaming` core registers `opfs://<filename>` paths
// (`WebDownloadService.registerUrl`). Neither `fetch()` nor
// `ort.InferenceSession.create()` understands that OPFS-private scheme, so the
// OPFS file itself — the `File` its handle returns, which the browser reads
// from disk — becomes a `blob:` URL. Every other path
// (`WebStorageMode.cacheApi` / `.none`: already a `blob:` or `https:` URL) is
// returned unchanged.
//
// Not a copy: this used to stream the file into a new Blob
// (`new Response(file.stream()).blob()`), one model-sized copy per load, held
// in the browser's blob storage until the Blob object was garbage-collected —
// revoking its URL does not free it. A page that loaded a few embedders ran
// out of blob storage (between 660 and 820 MB of copies on the GCE test VM's
// Chrome) and the next `blob()` failed with a bare "TypeError: Failed to
// fetch". A File-backed URL takes no blob storage and copies nothing.
//
// Same `ServiceRegistry.useStreamingStorage` + `WebDownloadService.opfsService`
// lookup `WebModelSourceResolver` does for inference models, but it produces a
// URL instead of a stream because its consumers want a URL. Moved from
// flutter_edge_ai_onnx's `resolveOnnxWebPath`, which reached into core's
// service registry to do it. Exported by `package:flutter_edge_ai/engine_web.dart`.
import 'dart:js_interop';

import 'package:flutter_edge_ai/src/di/service_registry.dart';
import 'package:flutter_edge_ai/src/infrastructure/web_download_service.dart';

/// `navigator.storage`: the OPFS root the `opfs_helper.js` downloads write to.
/// Read here directly, not through `window.flutterGemmaOPFS`, so an app's
/// copy of `opfs_helper.js` from an older release still works.
@JS('navigator.storage')
external _StorageManager get _storage;

extension type _StorageManager._(JSObject _) implements JSObject {
  external JSPromise<_DirectoryHandle> getDirectory();
}

extension type _DirectoryHandle._(JSObject _) implements JSObject {
  external JSPromise<_FileHandle> getFileHandle(JSString name);
}

extension type _FileHandle._(JSObject _) implements JSObject {
  /// A `File` snapshot of the OPFS file, read from disk when it is read.
  external JSPromise<JSObject> getFile();
}

@JS('URL.createObjectURL')
external JSString _createObjectUrlJs(JSAny blob);

/// Resolves [rawPath] — a model or tokenizer path core registered for an
/// installed file — to a URL that `fetch()` can load.
///
/// `opfs://<filename>` (streaming storage) becomes a `blob:` URL of that OPFS
/// file (the file itself, not a copy); any other path is returned unchanged.
/// Throws [StateError] when an `opfs://` path arrives while streaming storage
/// is not enabled or OPFS is not available, and an [Exception] naming the file
/// when OPFS has no such file.
///
/// Ownership: the `blob:` URL made for an `opfs://` path is a NEW object URL
/// that belongs to the caller. Revoke it (`URL.revokeObjectURL`) once its
/// consumer has read the file — on success and on failure alike. Any other
/// path is returned as it came and is not the caller's: never revoke it (core
/// may own it).
Future<String> resolveWebModelUrl(String rawPath) async {
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
  if (downloadService.opfsService == null) {
    throw StateError(
      'OPFS service not available for "$rawPath" (streaming mode requires '
      'OPFS).',
    );
  }

  final filename = rawPath.substring('opfs://'.length);
  final JSObject file;
  try {
    final root = await _storage.getDirectory().toDart;
    final handle = await root.getFileHandle(filename.toJS).toDart;
    file = await handle.getFile().toDart;
  } catch (e) {
    throw Exception('Model not found in OPFS: $filename ($e)');
  }
  return _createObjectUrlJs(file).toDart;
}

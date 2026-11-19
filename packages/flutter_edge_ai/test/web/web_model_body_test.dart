// The web download path keeps a model's bytes in the browser: the body of a
// `fetch` streams into the Cache API (or into a `Blob` when nothing is
// cached), with no Dart typed array in between.
//
// Under dart2wasm a Dart `Uint8List` is a WasmGC array, which V8 (Chrome 157)
// caps at 2^30 - 20 bytes in every build mode; above that `new Uint8List`
// traps with `RuntimeError: requested new array is too large`, no Dart `catch`
// sees it, and an install that concatenated the body into one `Uint8List`
// (as `WebJsInterop.fetchFile` did) never completed.
//
// Small bodies are served from `blob:` URLs, so `fetchBody` reads a real
// `fetch` stream without a server. The body over the dart2wasm limit is a
// `Response` over a generated `ReadableStream`, read back by the test: the
// test page's Chrome runs as a guest profile whose blob and Cache API storage
// live in memory and refuse 1.1 GiB (`blob:` fetch: "Failed to fetch"; Blob
// read: NotReadableError, under dart2js and dart2wasm alike). Storing a large
// model is the drive test's part (`litertlm_web_test.dart`). The registered
// blob URL of a cached model comes from the app's `cache_api.js`, which the
// test page does not load, so the Cache API half is checked through
// `cacheModel`. Run under both compilers:
//   flutter test test/web/web_model_body_test.dart --platform chrome
//   flutter test test/web/web_model_body_test.dart --platform chrome --wasm
// The body over the dart2wasm limit moves 1.1 GiB through the browser: about
// 5 s under dart2wasm, where it guards the fix and `tool/test_all.sh` runs it,
// and about 30 s under dart2js (DDC), where it is tagged `slow` and the
// script leaves it out.
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWasm;
import 'package:flutter_edge_ai/src/infrastructure/web_cache_interop_stub.dart'
    if (dart.library.js_interop) 'package:flutter_edge_ai/src/infrastructure/web_cache_interop.dart';
import 'package:flutter_edge_ai/src/infrastructure/web_cache_service.dart';
import 'package:flutter_edge_ai/src/infrastructure/web_file_system_service.dart';
import 'package:flutter_edge_ai/src/infrastructure/web_js_interop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

@JS('URL.createObjectURL')
external JSString _createObjectUrl(JSObject blob);

@JS('URL.revokeObjectURL')
external void _revokeObjectUrl(JSString url);

@JS('caches')
external _CacheStorage get _caches;

extension type _CacheStorage._(JSObject _) implements JSObject {
  external JSPromise<_Cache> open(JSString name);
  external JSPromise<JSBoolean> delete(JSString name);
}

extension type _Cache._(JSObject _) implements JSObject {
  external JSPromise<_Response?> match(JSString url);
}

@JS('Response')
extension type _Response._(JSObject _) implements JSObject {
  external factory _Response(JSObject? body);
  external _ReadableStream get body;
  external JSPromise<JSArrayBuffer> arrayBuffer();
}

@JS('Blob')
extension type _Blob._(JSObject _) implements JSObject {
  external factory _Blob(JSArray<JSAny> parts);
}

@JS('ReadableStream')
extension type _ReadableStream._(JSObject _) implements JSObject {
  external factory _ReadableStream(JSObject source);
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_ReadResult> read();
}

extension type _ReadResult._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

extension type _StreamController._(JSObject _) implements JSObject {
  external void enqueue(JSUint8Array chunk);
  external void close();
  external void error(JSAny reason);
}

/// A stream that gives [chunks] and then fails, or (when [fail] is false)
/// stays open forever.
_ReadableStream _stream(List<Uint8List> chunks, {bool fail = true}) {
  var next = 0;
  return _ReadableStream(
    JSObject()..setProperty(
      'pull'.toJS,
      ((_StreamController controller) {
        if (next < chunks.length) {
          controller.enqueue(chunks[next++].toJS);
        } else if (fail) {
          controller.error('network error'.toJS);
        }
      }).toJS,
    ),
  );
}

/// Byte `i` of a test body: `i * 7 + (i >> 16)` mod 256, so a chunk that is
/// dropped, repeated or reordered changes the content.
int _byteAt(int i) => (i * 7 + (i >> 16)) & 0xff;

Uint8List _pattern(int length, {int offset = 0}) {
  final bytes = Uint8List(length);
  for (var i = 0; i < length; i++) {
    bytes[i] = _byteAt(offset + i);
  }
  return bytes;
}

/// A `blob:` URL over [parts]; revoked at the end of the test.
String _serve(List<Uint8List> parts) {
  final blob = _Blob([for (final p in parts) p.toJS].toJS);
  final url = _createObjectUrl(blob).toDart;
  addTearDown(() => _revokeObjectUrl(url.toJS));
  return url;
}

/// Reads [body] to its end, as the Cache API would.
Future<Uint8List> _readAll(WebModelBody body) async {
  final response = _Response(body.body as JSObject);
  return (await response.arrayBuffer().toDart).toDart.asUint8List();
}

void main() {
  group('WebJsInterop.fetchBody', () {
    test('gives every byte in order and counts them', () async {
      // Several parts, so the stream gives more than one chunk.
      const part = 300 * 1024;
      final url = _serve([
        for (var i = 0; i < 5; i++) _pattern(part, offset: i * part),
      ]);
      final progress = <double>[];

      final body = await WebJsInterop().fetchBody(
        url,
        onProgress: progress.add,
      );

      expect(body.size, 0, reason: 'nothing is read before the reader asks');
      expect(await _readAll(body), _pattern(5 * part));
      expect(body.size, 5 * part);
      expect(progress, isNotEmpty);
      expect(progress.where((p) => p < 0), isEmpty);
      expect(progress.last, 1.0);
    });

    test('an empty body has size 0', () async {
      final body = await WebJsInterop().fetchBody(_serve([]));
      expect(await _readAll(body), isEmpty);
      expect(body.size, 0);
    });

    test('a failed request is a JsInteropException, not a hang', () async {
      final url = _serve([Uint8List(4)]);
      _revokeObjectUrl(url.toJS);

      await expectLater(
        WebJsInterop().fetchBody(url),
        throwsA(isA<JsInteropException>()),
      );
    });

    test('a cancel before the response aborts the request', () async {
      await expectLater(
        WebJsInterop().fetchBody(
          _serve([_pattern(4096)]),
          cancelled: Future<void>.value(),
        ),
        throwsA(isA<JsInteropException>()),
      );
    });

    test('abort makes the reader fail instead of finishing', () async {
      final body = await WebJsInterop().fetchBody(_serve([_pattern(4096)]));

      body.abort();

      await expectLater(_readAll(body), throwsA(anything));
    });

    test(
      'a body over the dart2wasm Uint8List limit passes through whole',
      () async {
        // 2^30 + 64 MiB: over V8's 2^30 - 20 byte WasmGC array cap, which a
        // body copied into one Dart Uint8List traps on under --wasm.
        const chunk = 64 * 1024 * 1024;
        const chunks = 17;
        const total = chunks * chunk;
        var sent = 0;
        final source = JSObject()
          ..setProperty(
            'pull'.toJS,
            ((_StreamController controller) {
              if (sent == chunks) {
                controller.close();
                return;
              }
              controller.enqueue(_pattern(chunk, offset: sent * chunk).toJS);
              sent++;
            }).toJS,
          );
        final progress = <double>[];

        final body = WebJsInterop().bodyOfResponse(
          _Response(_ReadableStream(source)),
          onProgress: progress.add,
        );

        // Read it back chunk by chunk, checking the bytes on each side of
        // the old limit and the last ones, never holding the whole body.
        const edge = (1 << 30) - 20;
        final reader = (body.body as _ReadableStream).getReader();
        var offset = 0;
        var checked = 0;
        while (true) {
          final result = await reader.read().toDart;
          if (result.done) break;
          final bytes = result.value!.toDart;
          for (final at in [edge - 1, edge, edge + 1, total - 1]) {
            if (at >= offset && at < offset + bytes.length) {
              expect(bytes[at - offset], _byteAt(at), reason: 'byte $at');
              checked++;
            }
          }
          offset += bytes.length;
        }

        expect(sent, chunks);
        expect(offset, total);
        expect(checked, 4);
        expect(body.size, total);
        expect(body.size, greaterThan(1 << 30));
        // No Content-Length on a generated stream: indeterminate, then done.
        expect(progress.last, 1.0);
      },
      tags: kIsWasm ? null : 'slow',
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('WebCacheService with a streamed body', () {
    const cacheKey = 'https://example.com/web-model-body-test.bin';

    Future<(WebCacheService, WebFileSystemService)> service({
      required bool enableCache,
    }) async {
      SharedPreferences.setMockInitialValues({});
      final fileSystem = WebFileSystemService();
      final cacheService = WebCacheService(
        WebCacheInterop(),
        await SharedPreferences.getInstance(),
        fileSystem,
        enableCache: enableCache,
      );
      await _caches.delete(WebCacheService.cacheName.toJS).toDart;
      addTearDown(() => _caches.delete(WebCacheService.cacheName.toJS).toDart);
      return (cacheService, fileSystem);
    }

    Future<_Response?> cached() async {
      final cache = await _caches.open(WebCacheService.cacheName.toJS).toDart;
      return cache.match(cacheKey.toJS).toDart;
    }

    test('cacheModel streams a download into the Cache API', () async {
      final (cacheService, _) = await service(enableCache: true);
      final bytes = _pattern(700 * 1024);
      final body = await WebJsInterop().fetchBody(_serve([bytes]));

      await cacheService.cacheModel(cacheKey, body);

      expect(body.size, bytes.length);
      final entry = await cached();
      expect(entry, isNotNull);
      expect((await entry!.arrayBuffer().toDart).toDart.asUint8List(), bytes);
    });

    test('a body that fails part-way leaves nothing in the cache', () async {
      final (cacheService, _) = await service(enableCache: true);
      final body = WebJsInterop().bodyOfResponse(
        _Response(_stream([_pattern(4096), _pattern(4096)])),
      );

      await expectLater(
        cacheService.cacheModel(cacheKey, body),
        throwsA(anything),
      );
      // It failed after reading some of the body (an error drops queued
      // chunks, so how much is not fixed).
      expect(body.size, greaterThan(0));
      expect(await cached(), isNull);
      expect(await cacheService.getCachedUrls(), isEmpty);
    });

    test('cancelling the install stream aborts the download', () async {
      final (cacheService, fileSystem) = await service(enableCache: false);
      var aborted = false;
      final events = cacheService.getOrCacheAndRegisterWithProgress(
        cacheKey: cacheKey,
        loader: (onProgress) async => WebJsInterop().bodyOfResponse(
          _Response(_stream([_pattern(1024)], fail: false)),
          onProgress: onProgress,
          abort: () => aborted = true,
        ),
        targetPath: 'web-model-body-test.bin',
      );

      // The first progress event, then the listener leaves.
      await events.first;

      expect(aborted, isTrue);
      expect(fileSystem.getUrl('web-model-body-test.bin'), isNull);
    });

    test('without the cache it registers a blob URL of the body', () async {
      final (cacheService, fileSystem) = await service(enableCache: false);
      final bytes = _pattern(64 * 1024);
      final progress = await cacheService
          .getOrCacheAndRegisterWithProgress(
            cacheKey: cacheKey,
            loader: (onProgress) => WebJsInterop().fetchBody(
              _serve([bytes]),
              onProgress: onProgress,
            ),
            targetPath: 'web-model-body-test.bin',
          )
          .toList();

      expect(progress.last, 100);
      final url = fileSystem.getUrl('web-model-body-test.bin')!;
      expect(url, startsWith('blob:'));
      expect(await _readAll(await WebJsInterop().fetchBody(url)), bytes);
      expect(await cached(), isNull);
    });

    test('an empty body is a StateError, not a registered model', () async {
      final (cacheService, fileSystem) = await service(enableCache: false);

      await expectLater(
        cacheService
            .getOrCacheAndRegisterWithProgress(
              cacheKey: cacheKey,
              loader: (_) => WebJsInterop().fetchBody(_serve([])),
              targetPath: 'web-model-body-test.bin',
            )
            .drain<void>(),
        throwsA(isA<StateError>()),
      );
      expect(fileSystem.getUrl('web-model-body-test.bin'), isNull);
    });

    test('a body from Dart bytes is cached too', () async {
      final (cacheService, _) = await service(enableCache: true);
      final bytes = _pattern(32 * 1024);

      await cacheService.cacheModel(cacheKey, WebModelBody.ofBytes(bytes));

      final entry = await cached();
      expect((await entry!.arrayBuffer().toDart).toDart.asUint8List(), bytes);
    });
  });
}

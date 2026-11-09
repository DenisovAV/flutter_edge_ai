// Reads the first bytes of the model file the engine is about to load.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_web.dart';

@JS('fetch')
external JSPromise<_Response> _fetch(JSString url, JSObject init);

extension type _Response._(JSObject _) implements JSObject {
  external bool get ok;
  external int get status;
  external _Body? get body;
}

extension type _Body._(JSObject _) implements JSObject {
  external _Reader getReader();
}

extension type _Reader._(JSObject _) implements JSObject {
  external JSPromise<_Chunk> read();
  external JSPromise<JSAny?> cancel();
}

extension type _Chunk._(JSObject _) implements JSObject {
  external bool get done;
  external JSUint8Array? get value;
}

/// The first [length] bytes of the file behind [source], or all of it when it
/// is shorter. The rest of the file is never downloaded or read.
Future<Uint8List> readModelPrefix(WebModelSource source, int length) async {
  switch (source) {
    case BlobUrlModelSource(:final url):
      return _readUrl(url, length);
    case OpfsStreamModelSource():
      final reader = await source.openReader();
      return _readReader(_Reader._(reader as JSObject), length);
  }
}

Future<Uint8List> _readUrl(String url, int length) async {
  final init = JSObject();
  if (url.startsWith('http:') || url.startsWith('https:')) {
    // `Range` is a CORS-safelisted header. A server that ignores it answers
    // with the whole file, which the read below stops after [length] bytes.
    final headers = JSObject()
      ..setProperty('Range'.toJS, 'bytes=0-${length - 1}'.toJS);
    init.setProperty('headers'.toJS, headers);
  }
  final response = await _fetch(url.toJS, init).toDart;
  if (!response.ok) {
    throw StateError('fetch($url) answered HTTP ${response.status}');
  }
  final body = response.body;
  if (body == null) return Uint8List(0);
  return _readReader(body.getReader(), length);
}

Future<Uint8List> _readReader(_Reader reader, int length) async {
  final bytes = BytesBuilder(copy: false);
  try {
    while (bytes.length < length) {
      final chunk = await reader.read().toDart;
      if (chunk.done) break;
      if (chunk.value case final value?) bytes.add(value.toDart);
    }
  } finally {
    try {
      // Stops the rest of the file: a prefix was wanted, not the model.
      await reader.cancel().toDart;
    } catch (e) {
      edgeAiLog('[MediaPipe Web] closing the model prefix read: $e');
    }
  }
  final read = bytes.takeBytes();
  return read.length > length ? Uint8List.sublistView(read, 0, length) : read;
}

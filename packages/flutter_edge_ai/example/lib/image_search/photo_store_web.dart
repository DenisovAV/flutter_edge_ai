import 'dart:async';
import 'dart:js_interop';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show sniffEncodedMediaFormat;
import 'package:web/web.dart' as web;

import 'photo_store.dart';

/// The web [PhotoStore]: picked photos are copied into the origin private
/// file system (OPFS), directory `image_search_photos/`, so a reference
/// outlives the page like the RAG index that stores it. Needs a browser with
/// `FileSystemFileHandle.createWritable` (Chrome, Edge, Firefox).
PhotoStore createPhotoStore() => _OpfsPhotoStore();

/// The reference of a photo this store kept: `opfs-photo:<file name>`.
const _scheme = 'opfs-photo:';
const _directoryName = 'image_search_photos';

Future<web.FileSystemDirectoryHandle> _root() =>
    web.window.navigator.storage.getDirectory().toDart;

Future<web.FileSystemDirectoryHandle> _directory() async => (await _root())
    .getDirectoryHandle(
      _directoryName,
      web.FileSystemGetDirectoryOptions(create: true),
    )
    .toDart;

final class _OpfsPhotoStore implements PhotoStore {
  int _counter = 0;

  @override
  Future<String> keep(Uint8List data, {required String name}) async {
    // The container from the bytes, not the picked name: a HEIC saved as
    // .jpg is still HEIC (and still refused before it reaches the engine).
    final extension = sniffEncodedMediaFormat(data)?.name ?? 'bin';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final fileName = 'photo-$stamp-${_counter++}.$extension';
    final directory = await _directory();
    final handle = await directory
        .getFileHandle(fileName, web.FileSystemGetFileOptions(create: true))
        .toDart;
    try {
      final writable = await handle.createWritable().toDart;
      try {
        await writable.write(data.toJS).toDart;
      } catch (_) {
        await _quietly('abort the write of $fileName', writable.abort().toDart);
        rethrow;
      }
      await writable.close().toDart;
    } catch (_) {
      // No reference reaches the caller, so nothing else would delete it.
      await _quietly(
        'delete the partial copy $fileName',
        directory.removeEntry(fileName).toDart,
      );
      rethrow;
    }
    return '$_scheme$fileName';
  }

  @override
  ImageProvider imageFor(String reference) =>
      assetImageFor(reference) ??
      (reference.startsWith(_scheme)
          ? _OpfsImage(reference.substring(_scheme.length))
          : throw ArgumentError.value(reference, 'reference', 'not a photo'));

  @override
  Future<void> forget(String reference) async {
    if (!reference.startsWith(_scheme)) return; // an asset, or not ours
    await (await _directory())
        .removeEntry(reference.substring(_scheme.length))
        .toDart;
  }

  @override
  Future<void> forgetAll() async {
    final root = await _root();
    // Created first, so removing it never fails on a store that kept nothing.
    await root
        .getDirectoryHandle(
          _directoryName,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    await root
        .removeEntry(
          _directoryName,
          web.FileSystemRemoveOptions(recursive: true),
        )
        .toDart;
  }
}

/// Runs a clean-up step whose failure must not hide the error being
/// rethrown: it is logged instead.
Future<void> _quietly(String what, Future<Object?> step) async {
  try {
    await step;
  } on Object catch (e) {
    debugPrint('[ImageSearch] could not $what: $e');
  }
}

/// A photo the store kept in OPFS, read when it is first shown. Equal by file
/// name, so the image cache decodes each one once.
@immutable
final class _OpfsImage extends ImageProvider<_OpfsImage> {
  const _OpfsImage(this.fileName);

  final String fileName;

  @override
  Future<_OpfsImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_OpfsImage>(this);

  @override
  ImageStreamCompleter loadImage(_OpfsImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _codec(decode),
        scale: 1,
        debugLabel: fileName,
      );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async {
    final handle = await (await _directory()).getFileHandle(fileName).toDart;
    final file = await handle.getFile().toDart;
    final bytes = (await file.arrayBuffer().toDart).toDart.asUint8List();
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) =>
      other is _OpfsImage && other.fileName == fileName;

  @override
  int get hashCode => fileName.hashCode;
}

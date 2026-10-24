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
/// file system (OPFS), directory `<directoryName>/`, so a reference outlives
/// the page like the RAG index that stores it. Needs a browser with
/// `FileSystemFileHandle.createWritable` (Chrome, Edge, Firefox).
PhotoStore createPhotoStore({String directoryName = 'image_search_photos'}) =>
    _OpfsPhotoStore(directoryName);

/// The reference of a photo this store kept: `opfs-photo:<file name>`, or
/// `opfs-photo:<directory>/<file name>` outside the default directory.
const _scheme = 'opfs-photo:';
const _defaultDirectory = 'image_search_photos';

Future<web.FileSystemDirectoryHandle> _root() =>
    web.window.navigator.storage.getDirectory().toDart;

Future<web.FileSystemDirectoryHandle> _directory(String name) async =>
    (await _root())
        .getDirectoryHandle(
          name,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;

/// The directory and file name of a reference this store kept.
({String directory, String file}) _locate(String reference) {
  final path = reference.substring(_scheme.length);
  final slash = path.indexOf('/');
  return slash < 0
      ? (directory: _defaultDirectory, file: path)
      : (directory: path.substring(0, slash), file: path.substring(slash + 1));
}

Future<Uint8List> _readFile(String reference) async {
  final (:directory, :file) = _locate(reference);
  final handle = await (await _directory(directory)).getFileHandle(file).toDart;
  final blob = await handle.getFile().toDart;
  return (await blob.arrayBuffer().toDart).toDart.asUint8List();
}

final class _OpfsPhotoStore implements PhotoStore {
  _OpfsPhotoStore(this._directoryName);

  final String _directoryName;
  int _counter = 0;

  String _referenceTo(String fileName) => _directoryName == _defaultDirectory
      ? '$_scheme$fileName'
      : '$_scheme$_directoryName/$fileName';

  @override
  Future<String> keep(Uint8List data, {required String name}) async {
    // The container from the bytes, not the picked name: a HEIC saved as
    // .jpg is still HEIC (and still refused before it reaches the engine).
    final extension = sniffEncodedMediaFormat(data)?.name ?? 'bin';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final fileName = 'photo-$stamp-${_counter++}.$extension';
    final directory = await _directory(_directoryName);
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
    return _referenceTo(fileName);
  }

  @override
  ImageProvider imageFor(String reference) =>
      assetImageFor(reference) ??
      (reference.startsWith(_scheme)
          ? _OpfsImage(reference)
          : throw ArgumentError.value(reference, 'reference', 'not a photo'));

  @override
  Future<Uint8List> read(String reference) {
    if (!reference.startsWith(_scheme)) {
      return Future.error(
        ArgumentError.value(reference, 'reference', 'not a kept photo'),
      );
    }
    return _readFile(reference);
  }

  @override
  Future<void> forget(String reference) async {
    if (!reference.startsWith(_scheme)) return; // an asset, or not ours
    final (:directory, :file) = _locate(reference);
    if (directory != _directoryName) return; // another store's
    await (await _directory(directory)).removeEntry(file).toDart;
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

/// A photo the store kept in OPFS, read when it is first shown. Equal by
/// reference, so the image cache decodes each one once.
@immutable
final class _OpfsImage extends ImageProvider<_OpfsImage> {
  const _OpfsImage(this.reference);

  final String reference;

  @override
  Future<_OpfsImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_OpfsImage>(this);

  @override
  ImageStreamCompleter loadImage(_OpfsImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _codec(decode),
        scale: 1,
        debugLabel: reference,
      );

  Future<ui.Codec> _codec(ImageDecoderCallback decode) async => decode(
    await ui.ImmutableBuffer.fromUint8List(await _readFile(reference)),
  );

  @override
  bool operator ==(Object other) =>
      other is _OpfsImage && other.reference == reference;

  @override
  int get hashCode => reference.hashCode;
}

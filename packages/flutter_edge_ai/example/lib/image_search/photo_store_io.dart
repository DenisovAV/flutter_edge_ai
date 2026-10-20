import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart'
    show sniffEncodedMediaFormat;
import 'package:path_provider/path_provider.dart';

import 'photo_store.dart';

/// The native [PhotoStore]: picked photos are copied into
/// `<documents>/<directoryName>/`.
PhotoStore createPhotoStore({String directoryName = 'image_search_photos'}) =>
    _FilePhotoStore(directoryName);

final class _FilePhotoStore implements PhotoStore {
  _FilePhotoStore(this._directoryName);

  final String _directoryName;
  int _counter = 0;

  Future<Directory> _directory() async {
    final documents = await getApplicationDocumentsDirectory();
    return Directory(
      '${documents.path}${Platform.pathSeparator}$_directoryName',
    ).create(recursive: true);
  }

  @override
  Future<String> keep(Uint8List data, {required String name}) async {
    // The container from the bytes, not the picked name: a HEIC saved as
    // .jpg is still HEIC (and still refused before it reaches the engine).
    final extension = sniffEncodedMediaFormat(data)?.name ?? 'bin';
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final file = File(
      '${(await _directory()).path}${Platform.pathSeparator}'
      'photo-$stamp-${_counter++}.$extension',
    );
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  @override
  ImageProvider imageFor(String reference) =>
      assetImageFor(reference) ?? FileImage(File(reference));

  @override
  Future<Uint8List> read(String reference) => File(reference).readAsBytes();

  @override
  Future<void> forget(String reference) async {
    if (assetKeyOf(reference) != null) return;
    final file = File(reference);
    if (file.parent.path != (await _directory()).path) return; // not ours
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> forgetAll() async {
    final directory = await _directory();
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

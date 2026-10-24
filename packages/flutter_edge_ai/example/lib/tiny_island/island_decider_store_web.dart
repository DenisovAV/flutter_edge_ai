import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'island_decider_store.dart';

/// The web: the origin private file system (OPFS), directory
/// `tiny_island_deciders/`, one `<model>.json` per model holding the
/// fingerprint and the artifact — so a page load with the same model and
/// catalog loads the decider instead of embedding the catalog again, and a
/// newer catalog's decider replaces the older one by overwriting it.
///
/// Needs `FileSystemFileHandle.createWritable` (Chrome, Edge, Firefox). A
/// browser without it fails the write, which the screen reports; it then
/// fits again on every page load, as before.
IslandDeciderStore createIslandDeciderStore() => OpfsIslandDeciderStore();

final class OpfsIslandDeciderStore implements IslandDeciderStore {
  static const _directoryName = 'tiny_island_deciders';

  @override
  String get where => "the browser's private file system (OPFS)";

  static String _fileName(String model) =>
      '${model.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}.json';

  Future<web.FileSystemFileHandle> _handle(String model) async {
    final root = await web.window.navigator.storage.getDirectory().toDart;
    final directory = await root
        .getDirectoryHandle(
          _directoryName,
          web.FileSystemGetDirectoryOptions(create: true),
        )
        .toDart;
    // Created when missing, so an absent decider reads as an empty file
    // instead of a DOMException the two web compilers surface differently.
    return directory
        .getFileHandle(
          _fileName(model),
          web.FileSystemGetFileOptions(create: true),
        )
        .toDart;
  }

  @override
  Future<Map<String, Object?>?> read({
    required String model,
    required String fingerprint,
  }) async {
    final file = await (await _handle(model)).getFile().toDart;
    if (file.size == 0) return null;
    final text = (await file.text().toDart).toDart;
    final decoded = jsonDecode(text);
    if (decoded is! Map<String, Object?> ||
        decoded['fingerprint'] is! String ||
        decoded['artifact'] is! Map<String, Object?>) {
      throw FormatException(
        'OPFS $_directoryName/${_fileName(model)} does not hold a stored '
        'decider',
      );
    }
    // Another fingerprint is an older catalog's decider: not this one.
    return decoded['fingerprint'] == fingerprint
        ? decoded['artifact'] as Map<String, Object?>
        : null;
  }

  @override
  Future<String?> write({
    required String model,
    required String fingerprint,
    required Map<String, Object?> artifact,
  }) async {
    final handle = await _handle(model);
    // createWritable writes aside and replaces the file on close: a page
    // closed mid-write keeps the previous file.
    final writable = await handle.createWritable().toDart;
    try {
      await writable
          .write(
            jsonEncode({'fingerprint': fingerprint, 'artifact': artifact}).toJS,
          )
          .toDart;
    } catch (_) {
      // The write's own error is the one to report, not the abort's.
      try {
        await writable.abort().toDart;
      } catch (_) {}
      rethrow;
    }
    await writable.close().toDart;
    return null;
  }
}

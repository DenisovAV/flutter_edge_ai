import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'island_decider_store.dart';

/// Native: `<app cache>/tiny_island_deciders/<model>--<fingerprint>.json`.
IslandDeciderStore createIslandDeciderStore() =>
    FileIslandDeciderStore(() async {
      final cache = await getApplicationCacheDirectory();
      return Directory(
        '${cache.path}${Platform.pathSeparator}tiny_island_deciders',
      );
    });

/// One JSON file per model and fingerprint in the directory [_directory]
/// returns (created on first write).
final class FileIslandDeciderStore implements IslandDeciderStore {
  FileIslandDeciderStore(this._directory);

  final Future<Directory> Function() _directory;

  @override
  String get where => "the app's cache directory";

  static String _prefix(String model) =>
      '${model.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}--';

  Future<File> _file(String model, String fingerprint) async {
    final directory = await _directory();
    return File(
      '${directory.path}${Platform.pathSeparator}'
      '${_prefix(model)}$fingerprint.json',
    );
  }

  @override
  Future<Map<String, Object?>?> read({
    required String model,
    required String fingerprint,
  }) async {
    final file = await _file(model, fingerprint);
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        '${file.path} holds a ${decoded.runtimeType}, not a decider artifact',
      );
    }
    return decoded;
  }

  @override
  Future<String?> write({
    required String model,
    required String fingerprint,
    required Map<String, Object?> artifact,
  }) async {
    final directory = await (await _directory()).create(recursive: true);
    final file = await _file(model, fingerprint);
    // Written aside, then renamed: a crash mid-write never leaves a short
    // file under the real name.
    final partial = File('${file.path}.partial');
    await partial.writeAsString(jsonEncode(artifact), flush: true);
    await partial.rename(file.path);

    final problems = <String>[];
    final prefix = _prefix(model);
    await for (final entity in directory.list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is! File ||
          !name.startsWith(prefix) ||
          entity.path == file.path) {
        continue;
      }
      try {
        await entity.delete();
      } on FileSystemException catch (e) {
        problems.add('could not remove the older $name: ${e.message}');
      }
    }
    return problems.isEmpty ? null : problems.join('; ');
  }
}

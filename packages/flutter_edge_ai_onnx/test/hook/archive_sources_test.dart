import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_edge_ai_onnx/src/hook/archive_sources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tmp;
  late File dest;
  final good = utf8.encode('the pinned archive');
  final goodSha = sha256.convert(good).toString();
  final official = Uri.parse('https://github.com/microsoft/onnxruntime/a.tgz');
  final mirror = Uri.parse(
    'https://github.com/DenisovAV/flutter_edge_ai/a.tgz',
  );

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('archive_sources_test');
    dest = File('${tmp.path}/a.tgz');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  /// A fetcher serving [bodies] by URL; a URL that is absent answers 404.
  ArchiveFetch serving(Map<Uri, List<int>> bodies, List<Uri> asked) =>
      (url, file, log) async {
        asked.add(url);
        final body = bodies[url];
        if (body == null) {
          log('download failed (HTTP 404) for $url');
          return false;
        }
        file.writeAsBytesSync(body);
        return true;
      };

  test('an unavailable official URL falls through to the mirror', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({mirror: good}, asked),
      log: (_) {},
    );
    expect(result.ok, isTrue);
    expect(result.source, mirror);
    expect(asked, [official, mirror]);
    expect(dest.readAsBytesSync(), good);
  });

  test('the first source that serves the pinned bytes wins', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({official: good, mirror: good}, asked),
      log: (_) {},
    );
    expect(result.source, official);
    expect(asked, [official]);
  });

  test('different bytes are an error, and no later source is tried', () async {
    final asked = <Uri>[];
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({official: utf8.encode('tampered'), mirror: good}, asked),
      log: (_) {},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('CHECKSUM MISMATCH'));
    expect(result.error, contains('$official'));
    expect(asked, [official]);
    expect(dest.existsSync(), isFalse);
  });

  test('no source serving the file names every source tried', () async {
    final result = await fetchPinnedArchive(
      sources: [official, mirror],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({}, []),
      log: (_) {},
    );
    expect(result.ok, isFalse);
    expect(result.error, contains('$official'));
    expect(result.error, contains('$mirror'));
    expect(dest.existsSync(), isFalse);
  });

  test('an empty source list is an error', () async {
    final result = await fetchPinnedArchive(
      sources: const [],
      sha256Hex: goodSha,
      dest: dest,
      fetch: serving({}, []),
      log: (_) {},
    );
    expect(result.ok, isFalse);
  });

  test(
    'every Microsoft archive in the hook is mirrored under its own name',
    () {
      // The hook lists Microsoft's release URL and, right after it, the same
      // file on this repository's mirror release; a URL list that names
      // Microsoft without the mirror would break with the next 404.
      final hook = File('hook/build.dart').readAsStringSync();
      final joined = hook.replaceAll(RegExp(r"'\s*\n\s*'"), '');
      final official = RegExp(
        r"https://github\.com/microsoft/(onnxruntime(?:-genai)?)/releases/"
        r"download/v([0-9.]+)/([^']+)'",
      ).allMatches(joined).toList();
      expect(official, isNotEmpty);
      for (final m in official) {
        final mirror =
            'https://github.com/DenisovAV/flutter_edge_ai/releases/download/'
            'mirror-${m[1]}-v${m[2]}/${m[3]}';
        final next = joined.substring(m.end, m.end + mirror.length + 40);
        expect(next, contains(mirror), reason: 'no mirror after ${m[3]}');
      }
    },
  );
}

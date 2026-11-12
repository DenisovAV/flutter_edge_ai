// Evidence hashes a model file once per version of it, compares sha256
// without regard to case, and names a file it cannot read instead of
// throwing.

import 'dart:async';
import 'dart:io';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

import '../integration_test/registry_evidence.dart';

/// sha256 of three zero bytes.
const _zeros3 =
    '709e80c88487a2411e1ee4dfb9f22a861492d20c4765150c0c794abd70f8147c';

ModelArtifact _artifact(String sha256) => ModelArtifact(
  repo: 'org/m',
  revision: '0123456789abcdef0123456789abcdef01234567',
  path: 'm.bin',
  sha256: sha256,
  sizeBytes: 3,
  installFilename: 'm.bin',
);

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('fea_evidence_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a file is hashed once until it changes', () async {
    final file = File('${dir.path}/m.bin')..writeAsBytesSync([0, 0, 0]);
    final before = fileHashCount;
    expect(await fileSha256(file.path), _zeros3);
    expect(await fileSha256(file.path), _zeros3);
    expect(fileHashCount - before, 1);
    file.writeAsBytesSync([0, 0, 0, 0]);
    expect(await fileSha256(file.path), isNot(_zeros3));
    expect(fileHashCount - before, 2);
    // The same size, other bytes, a later modification time: hashed again.
    file
      ..writeAsBytesSync([1, 1, 1, 1])
      ..setLastModifiedSync(DateTime.now().add(const Duration(minutes: 1)));
    expect(await fileSha256(file.path), isNot(_zeros3));
    expect(fileHashCount - before, 3);
  });

  test('a hash that fails another way is a reason too', () async {
    final path = (File('${dir.path}/m.bin')..writeAsBytesSync([0, 0, 0])).path;
    expect(
      await pinnedBytesProblem(
        path,
        _artifact(_zeros3),
        'v',
        hash: (_) async => throw StateError('isolate died'),
      ),
      'cannot hash $path: Bad state: isolate died',
    );
  });

  test('pinned bytes are compared without regard to case', () async {
    final path = (File('${dir.path}/m.bin')..writeAsBytesSync([0, 0, 0])).path;
    expect(
      await pinnedBytesProblem(path, _artifact(_zeros3.toUpperCase()), 'v'),
      isNull,
    );
    expect(
      await pinnedBytesProblem(path, _artifact('a' * 64), 'v'),
      'not the pinned bytes of v',
    );
  });

  test('a registry build is found by its sha256 in any case', () {
    final generic = LiteRtLmModels.gemma4E2bIt.generic;
    final hex = generic.files.first.sha256;
    for (final h in [hex.toLowerCase(), hex.toUpperCase()]) {
      expect(
        variantWithSha256(h, [LiteRtLmModels.gemma4E2bIt])?.id,
        generic.id,
      );
    }
  });

  test('a file that cannot be read is a reason, not an error', () async {
    if (Platform.isWindows) return; // no chmod
    final file = File('${dir.path}/locked.bin')..writeAsBytesSync([0, 0, 0]);
    Process.runSync('chmod', ['000', file.path]);
    addTearDown(() => Process.runSync('chmod', ['644', file.path]));
    if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
      return; // root reads it anyway
    }
    expect(
      await pinnedBytesProblem(file.path, _artifact(_zeros3), 'v'),
      startsWith('cannot read'),
    );
    expect(
      await pinnedBytesProblem('${dir.path}/none', _artifact(_zeros3), 'v'),
      startsWith('not installed'),
    );
  });

  test('a catalog error is the test\'s failure, not a skip', () async {
    // The catalog is not initialized here: FlutterEdgeAi.catalog throws.
    final path = (File('${dir.path}/m.bin')..writeAsBytesSync([0, 0, 0])).path;
    await expectLater(
      recordEvidence(path: path, backend: PreferredBackend.cpu, check: 'x'),
      throwsStateError,
    );
  });

  test(
    'a model that reports no backend is a skip, before the catalog',
    () async {
      // The catalog is not initialized here: reading it would throw.
      final path = (File(
        '${dir.path}/m.bin',
      )..writeAsBytesSync([0, 0, 0])).path;
      final lines = <String>[];
      await runZoned(
        () => recordEvidence(path: path, backend: null, check: 'x'),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => lines.add(line),
        ),
      );
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('FEA_EVIDENCE_SKIP '));
      expect(lines.single, contains('the model reports no backend'));
    },
  );

  group('companions', () {
    // Gecko: a .tflite and its tokenizer.
    final gecko = LiteRtEmbedders.gecko110mEn.variants.first;
    final tokenizer = gecko.files[1].sha256;
    Future<String> hash(String path) async => switch (path) {
      'tokenizer' => tokenizer.toUpperCase(),
      'other' => _zeros3,
      _ => throw FileSystemException('no such file', path),
    };

    test('a one-file variant needs none and ignores any', () async {
      final variant = LiteRtLmModels.gemma4E2bIt.generic;
      expect(variant.files, hasLength(1));
      expect(await companionProblem(variant, const []), isNull);
      expect(
        await companionProblem(variant, const ['other'], hash: hash),
        isNull,
      );
    });

    test('every other file pinned, in any order: records', () async {
      expect(gecko.files, hasLength(2));
      expect(
        await companionProblem(gecko, const ['other', 'tokenizer'], hash: hash),
        isNull,
      );
    });

    test(
      'a companion with other bytes, or none: a reason naming the file',
      () async {
        for (final companions in const [
          <String>[],
          ['other'],
          ['missing'],
        ]) {
          final reason = await companionProblem(gecko, companions, hash: hash);
          expect(reason, contains(gecko.files[1].path), reason: '$companions');
          expect(reason, contains(gecko.id), reason: '$companions');
        }
        expect(
          await companionProblem(gecko, const ['missing'], hash: hash),
          contains('cannot read it'),
        );
      },
    );
  });
}

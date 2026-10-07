// The live leg (live_hugging_face_test.dart) cannot run on a pull request, so
// its checks are tested here instead: each one in catalog_checks.dart is
// handed the input that must fail it — a listing that is empty or cut off, a
// manifest that disagrees with its repo, a resolver that answers wrongly in
// one way. A check that lets such an input through fails this file, offline,
// in the default `flutter test`.
@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart'
    show ModelRuntimeDefaults, ResolvedHfModel;
import 'package:flutter_edge_ai_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

import 'catalog_checks.dart';

/// One entry of `/api/models?…&full=true`.
Map<String, dynamic> _model(
  String id,
  List<String> files, {
  Object? gated = false,
  bool private = false,
}) => {
  'id': id,
  'private': private,
  'gated': gated,
  'siblings': [
    for (final f in files) {'rfilename': f},
  ],
};

Matcher _refuses(String because) => throwsA(
  isA<StateError>().having((e) => e.message, 'message', contains(because)),
);

/// A deep copy, so a test can bend a fixture without touching the snapshot.
Map<String, dynamic> _copy(Map<String, dynamic> m) =>
    jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

/// The repo tree Hugging Face would answer for a manifest that is right.
List<Map<String, dynamic>> _treeFor(Map<String, dynamic> manifest) => [
  {'path': 'README.md', 'size': 1},
  for (final v in (manifest['variants'] as List).cast<Map<String, dynamic>>())
    {
      'path': v['file'],
      'size': 135,
      'lfs': {'oid': v['sha256'], 'size': v['size_bytes']},
    },
];

const _keep = Object();

/// [r] with some fields replaced; `_keep` leaves one as it is, so a field can
/// also be replaced by null.
ResolvedHfModel _answer(
  ResolvedHfModel r, {
  String? file,
  String? url,
  String? sha256,
  int? sizeBytes,
  List<String>? notes,
  Object? maxTokens = _keep,
  Object? backend = _keep,
  Object? thinkingDeclared = _keep,
  Object? supportImage = _keep,
  Object? supportAudio = _keep,
}) {
  T? pick<T>(Object? replacement, T? current) =>
      identical(replacement, _keep) ? current : replacement as T?;
  return ResolvedHfModel(
    file: file ?? r.file,
    url: url ?? r.url,
    fileType: r.fileType,
    modelType: r.modelType,
    sha256: sha256 ?? r.sha256,
    sizeBytes: sizeBytes ?? r.sizeBytes,
    notes: notes ?? r.notes,
    runtime: ModelRuntimeDefaults(
      maxTokens: pick(maxTokens, r.runtime.maxTokens),
      preferredBackend: pick(backend, r.runtime.preferredBackend),
      thinkingDeclared: pick(thinkingDeclared, r.runtime.thinkingDeclared),
      supportImage: pick(supportImage, r.runtime.supportImage),
      supportAudio: pick(supportAudio, r.runtime.supportAudio),
      minOutputTokens: r.runtime.minOutputTokens,
    ),
  );
}

/// What a wrong resolver does to a right answer, given what was asked and
/// what the same question answers without the backend hint.
typedef _Bend =
    ResolvedHfModel Function(
      ResolvedHfModel right,
      PreferredBackend? hint,
      ResolvedHfModel withoutHint,
    );

/// The real resolver over [manifest], wrong in exactly the way [bend] says.
ManifestResolve _resolverThat(Map<String, dynamic> manifest, _Bend bend) {
  final real = LitertlmManifestResolver(
    fetch: (url, headers) async => jsonEncode(manifest),
  );
  return (repo, {platform, preferredBackend}) async => bend(
    await real.resolve(
      repo,
      platform: platform,
      preferredBackend: preferredBackend,
    ),
    preferredBackend,
    await real.resolve(repo, platform: platform),
  );
}

void main() {
  final snapshot = loadSnapshot();
  const repo = 'litert-community/SmolLM3-3B';
  final manifest = snapshot[repo]!;

  group('reposShippingManifest', () {
    List<ListedRepo> list(Object? listing, {int limit = 1000, String? link}) =>
        reposShippingManifest(
          jsonEncode(listing),
          org: 'org',
          limit: limit,
          linkHeader: link,
        );

    final listing = [
      _model('org/a', ['README.md', manifestFileName, 'a.litertlm']),
      _model('org/b', ['README.md', 'b.task']),
      _model('org/c', [manifestFileName], gated: 'auto'),
      _model('org/d', [manifestFileName], private: true),
    ];

    test('returns the public repos whose files include the manifest', () {
      expect(list(listing), [
        (id: 'org/a', gated: false),
        (id: 'org/c', gated: true),
      ]);
    });

    test('an org where nothing ships a manifest is an empty answer', () {
      expect(list([listing[1]]), isEmpty);
    });

    test('refuses an empty listing', () {
      expect(() => list(const []), _refuses('is empty'));
    });

    test('refuses a listing that is not a list (an API error object)', () {
      expect(
        () => list({'error': 'Too Many Requests'}),
        _refuses('not a JSON list'),
      );
    });

    test('refuses a listing that fills the page', () {
      expect(() => list(listing, limit: 4), _refuses('may be cut off'));
      expect(list(listing, limit: 5), hasLength(2));
    });

    test('refuses a listing whose Link header names a next page', () {
      expect(
        () => list(
          listing,
          link: '<https://huggingface.co/api/models?cursor=x>; rel="next"',
        ),
        _refuses('may be cut off'),
      );
    });

    test(
      'refuses an entry without file names (answered without full=true)',
      () {
        expect(
          () => list([
            listing.first,
            {'id': 'org/b'},
          ]),
          _refuses('no id or no siblings'),
        );
      },
    );
  });

  group('isGatedRefusal', () {
    final manifestUrl = Uri.parse('https://huggingface.co/org/a/resolve/main');
    ManifestFetchException status(int? code) =>
        ManifestFetchException(manifestUrl, 'GET failed', statusCode: code);

    test('is a gated repo answering 401 or 403', () {
      expect(isGatedRefusal(status(401), gated: true), isTrue);
      expect(isGatedRefusal(status(403), gated: true), isTrue);
    });

    test('is not an open repo answering 401, nor a gated one failing '
        'otherwise', () {
      expect(isGatedRefusal(status(401), gated: false), isFalse);
      expect(isGatedRefusal(status(404), gated: true), isFalse);
      expect(isGatedRefusal(status(null), gated: true), isFalse);
      expect(isGatedRefusal(const FormatException(), gated: true), isFalse);
    });
  });

  group('lfsMismatches', () {
    test('is empty when the manifest and the repo tree agree', () {
      expect(lfsMismatches(repo, manifest, _treeFor(manifest)), isEmpty);
    });

    test('names a variant whose sha256 or size_bytes is not the file\'s', () {
      final tree = _treeFor(manifest);
      final file = tree[1]['path'] as String;
      (tree[1]['lfs'] as Map)['oid'] = 'f' * 64;
      (tree[1]['lfs'] as Map)['size'] = 7;
      expect(lfsMismatches(repo, manifest, tree), [
        startsWith('$repo: $file sha256 '),
        startsWith('$repo: $file size_bytes '),
      ]);
    });

    test('names a variant the repo does not hold', () {
      final tree = _treeFor(manifest)..removeAt(1);
      expect(lfsMismatches(repo, manifest, tree), [
        endsWith('is not in the repo tree'),
      ]);
    });

    test('reads the size of a file kept outside LFS from the entry', () {
      final tree = _treeFor(manifest);
      final variant =
          (manifest['variants'] as List).first as Map<String, dynamic>;
      tree[1]
        ..remove('lfs')
        ..['size'] = variant['size_bytes'];
      // The size agrees; the sha256 cannot — the tree gives none.
      expect(lfsMismatches(repo, manifest, tree), [
        startsWith('$repo: ${variant['file']} sha256 '),
      ]);
    });

    test('does not compare a field the manifest does not state', () {
      final bare = _copy(manifest);
      for (final v in (bare['variants'] as List).cast<Map<String, dynamic>>()) {
        v
          ..remove('sha256')
          ..remove('size_bytes');
      }
      expect(lfsMismatches(repo, bare, _treeFor(manifest)), isEmpty);
      // …but the file still has to be there.
      expect(
        lfsMismatches(repo, bare, _treeFor(manifest)..removeAt(1)),
        hasLength(1),
      );
    });
  });

  group('expectResolverInvariants', () {
    // One variant, verified on cpu and gpu, cpu by default: every wrong
    // answer below can be given without leaving the manifest.
    const repo = 'litert-community/InternVL3-1B';
    final manifest = snapshot[repo]!;
    final variant =
        (manifest['variants'] as List).single as Map<String, dynamic>;
    PreferredBackend other(PreferredBackend? b) =>
        b == PreferredBackend.cpu ? PreferredBackend.gpu : PreferredBackend.cpu;
    // The line the resolver adds when it drops a hint and lands on [landed].
    String dropNote(String repo, PreferredBackend landed) =>
        'No variant of "$repo" is verified on the requested npu backend; '
        'resolved without that hint (${landed.name}).';

    test('the fixture is the shape the wrong answers below rely on', () {
      expect(variant['backends'], ['cpu', 'gpu']);
    });

    test('asks for every platform key with every backend hint', () async {
      final asked = <String>{};
      final real = LitertlmManifestResolver(
        fetch: (url, headers) async => jsonEncode(manifest),
      );
      final combinations = await expectResolverInvariants(
        repo,
        manifest,
        resolve: (repo, {platform, preferredBackend}) {
          asked.add('$platform|${preferredBackend?.name}');
          return real.resolve(
            repo,
            platform: platform,
            preferredBackend: preferredBackend,
          );
        },
      );
      expect(combinations, 32);
      expect(asked, {
        for (final platform in const [
          null,
          'android',
          'ios',
          'macos',
          'windows',
          'linux',
          'web',
          'unknown',
        ])
          for (final hint in const [null, 'cpu', 'gpu', 'npu'])
            '$platform|$hint',
      });
    });

    // Each entry is a resolver that is wrong in one way, and right in every
    // other — so that one expectation, and no neighbour, is what fails it.
    // Remove or loosen that expectation and its entry gets through.
    final wrong = <String, _Bend>{
      'a file that is not a variant of the repo': (r, hint, _) => _answer(
        r,
        file: 'elsewhere.litertlm',
        url: 'https://huggingface.co/$repo/resolve/main/elsewhere.litertlm',
      ),
      'a URL off the repo\'s own /resolve/main/ path': (r, hint, _) =>
          _answer(r, url: r.url.replaceFirst('/resolve/main/', '/blob/main/')),
      'a sha256 that is not the variant\'s': (r, hint, _) =>
          _answer(r, sha256: 'f' * 64),
      'a size that is not the variant\'s': (r, hint, _) =>
          _answer(r, sizeBytes: 1),
      'no backend at all': (r, hint, _) => _answer(r, backend: null),
      // npu wherever nothing else forbids it: with no hint, and — keeping the
      // drop on the record — when npu itself was asked for.
      'a backend the variant is not verified on': (r, hint, withoutHint) =>
          switch (hint) {
            null => _answer(r, backend: PreferredBackend.npu),
            PreferredBackend.npu => _answer(
              r,
              backend: PreferredBackend.npu,
              notes: [
                ...withoutHint.notes,
                dropNote(repo, PreferredBackend.npu),
              ],
            ),
            _ => r,
          },
      'another backend than the listed one that was asked for': (r, hint, _) =>
          hint == PreferredBackend.cpu
          ? _answer(r, backend: PreferredBackend.gpu)
          : r,
      'a dropped-hint note on a hint that was honoured': (r, hint, _) =>
          hint == PreferredBackend.gpu
          ? _answer(r, notes: [...r.notes, 'x resolved without that hint x'])
          : r,
      'a substitute for a hint nothing lists': (r, hint, withoutHint) {
        if (hint != PreferredBackend.npu) return r;
        final substitute = other(withoutHint.runtime.preferredBackend);
        return _answer(
          r,
          backend: substitute,
          notes: [...withoutHint.notes, dropNote(repo, substitute)],
        );
      },
      'a dropped hint that leaves no note': (r, hint, withoutHint) =>
          hint == PreferredBackend.npu ? withoutHint : r,
      'a context length that is not the manifest\'s': (r, hint, _) =>
          _answer(r, maxTokens: (r.runtime.maxTokens ?? 0) + 1),
      'thinking the manifest does not declare': (r, hint, _) =>
          _answer(r, thinkingDeclared: !r.runtime.thinkingDeclared!),
      'vision the manifest does not declare': (r, hint, _) =>
          _answer(r, supportImage: !r.runtime.supportImage!),
      'audio the manifest does not declare': (r, hint, _) =>
          _answer(r, supportAudio: !r.runtime.supportAudio!),
    };
    for (final entry in wrong.entries) {
      test('fails a resolver that answers ${entry.key}', () async {
        await expectLater(
          expectResolverInvariants(
            repo,
            manifest,
            resolve: _resolverThat(manifest, entry.value),
          ),
          throwsA(isA<TestFailure>()),
        );
      });
    }

    test('fails a resolver that answers a dropped hint with another file '
        'than the hint-free one', () async {
      // Needs two variants to choose between: SmolLM3-3B, both verified on
      // cpu and gpu.
      const repo = 'litert-community/SmolLM3-3B';
      final manifest = snapshot[repo]!;
      final variants = (manifest['variants'] as List)
          .cast<Map<String, dynamic>>();
      expect(variants, hasLength(2));
      await expectLater(
        expectResolverInvariants(
          repo,
          manifest,
          resolve: _resolverThat(manifest, (r, hint, withoutHint) {
            if (hint != PreferredBackend.npu) return r;
            final elsewhere = variants.firstWhere(
              (v) => v['file'] != withoutHint.file,
            );
            return _answer(
              r,
              file: elsewhere['file'] as String,
              url:
                  'https://huggingface.co/$repo/resolve/main/'
                  '${elsewhere['file']}',
              sha256: elsewhere['sha256'] as String,
              sizeBytes: elsewhere['size_bytes'] as int,
            );
          }),
        ),
        throwsA(isA<TestFailure>()),
      );
    });

    test('fails on a backend name the plugin has no value for', () async {
      final odd = _copy(manifest);
      for (final v in (odd['variants'] as List).cast<Map<String, dynamic>>()) {
        v['backends'] = ['webgpu'];
        v['default_backend'] = 'webgpu';
        v.remove('recommended');
      }
      await expectLater(
        expectResolverInvariants(repo, odd),
        throwsA(isA<TestFailure>()),
      );
    });

    test('fails with the resolver\'s FormatException on a manifest it '
        'refuses', () async {
      for (final refused in [
        _copy(manifest)..['variants'] = const [],
        _copy(manifest)..remove('variants'),
        _copy(manifest)..['manifest_schema'] = '0.2.0',
      ]) {
        await expectLater(
          expectResolverInvariants(repo, refused),
          throwsFormatException,
        );
      }
    });

    test('a manifest without a capabilities block must resolve to nulls, '
        'not to false', () async {
      final silent = _copy(manifest);
      (silent['model'] as Map).remove('capabilities');
      expect(await expectResolverInvariants(repo, silent), 32);
      for (final answer in <_Bend>[
        (r, hint, _) => _answer(r, thinkingDeclared: false),
        (r, hint, _) => _answer(r, supportImage: false),
        (r, hint, _) => _answer(r, supportAudio: false),
      ]) {
        await expectLater(
          expectResolverInvariants(
            repo,
            silent,
            resolve: _resolverThat(silent, answer),
          ),
          throwsA(isA<TestFailure>()),
        );
      }
    });
  });

  group('snapshotDifference', () {
    test('says so when the catalog is the snapshot', () {
      final report = snapshotDifference(snapshot, snapshot);
      expect(report, contains('No difference.'));
      expect(report, contains('serves ${snapshot.length} manifests'));
    });

    test('lists what was added, removed and changed', () {
      final live = {for (final e in snapshot.entries) e.key: _copy(e.value)};
      live.remove('litert-community/Jan-nano');
      live['org/new'] = _copy(manifest);
      final variants = (live[repo]!['variants'] as List)
          .cast<Map<String, dynamic>>();
      variants[0]['sha256'] = 'f' * 64;
      variants[1]['size_bytes'] = 7;
      live[repo]!['generated'] = '2099-01-01';
      const curated = 'litert-community/InternVL3-1B';
      ((live[curated]!['variants'] as List).single as Map)['quantization'] =
          'another recipe';

      final report = snapshotDifference(snapshot, live);
      expect(report, isNot(contains('No difference.')));
      expect(report, contains('**Served, not in the snapshot (1)**'));
      expect(report, contains('- `org/new`'));
      expect(report, contains('**In the snapshot, no longer served (1)**'));
      expect(report, contains('- `litert-community/Jan-nano`'));
      expect(report, contains('**Changed since the snapshot (2)**'));
      expect(
        report,
        contains(
          '- `$repo`: ${variants[0]['file']} (sha256); '
          '${variants[1]['file']} (size_bytes); generated',
        ),
      );
      expect(
        report,
        contains('- `$curated`: InternVL3-1B.litertlm (other fields)'),
      );
    });

    test('reports a manifest it cannot read instead of throwing', () {
      final live = {for (final e in snapshot.entries) e.key: _copy(e.value)};
      live[repo]!['variants'] = 'not a list';
      const nameless = 'litert-community/InternVL3-1B';
      ((live[nameless]!['variants'] as List).single as Map).remove('file');

      final report = snapshotDifference(snapshot, live);
      expect(report, contains('**Changed since the snapshot (2)**'));
      expect(report, contains('- `$repo`: -SmolLM3-3B.litertlm'));
      expect(report, contains('- `$nameless`: -InternVL3-1B.litertlm'));
    });
  });
}

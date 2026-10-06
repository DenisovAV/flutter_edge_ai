// Checks shared by the offline sweep (shipped_manifests_regression_test.dart,
// over the committed snapshot) and the live leg (live_hugging_face_test.dart,
// over what Hugging Face serves today).
//
// Nothing here touches the network: each check takes the bytes or the parsed
// JSON it judges, and the resolver it judges is a parameter. So
// catalog_checks_test.dart can hand each check the input that must fail it,
// offline, on every pull request. What only the live leg holds — the HTTP,
// which repo a failure is attributed to, the end-to-end comparison — has no
// offline test.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart'
    show ResolvedHfModel;
import 'package:flutter_edge_ai_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_test/flutter_test.dart';

/// The file a repo ships at its root to be resolvable.
const manifestFileName = 'litertlm_manifest.json';

/// Every platform key core can send, plus none.
const platformKeys = [
  null,
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'web',
  'unknown',
];

/// Every backend hint, plus none. No variant of the snapshot is verified on
/// npu, so there it exercises the hint-drop lane (the resolver resolves
/// without the hint) on every repo.
const backendHints = [
  null,
  PreferredBackend.cpu,
  PreferredBackend.gpu,
  PreferredBackend.npu,
];

String wireName(PreferredBackend b) => switch (b) {
  PreferredBackend.cpu => 'cpu',
  PreferredBackend.gpu => 'gpu',
  PreferredBackend.npu => 'npu',
};

/// The resolver call the invariants judge — [LitertlmManifestResolver.resolve]
/// over one manifest, or a stand-in that answers wrongly on purpose.
typedef ManifestResolve =
    Future<ResolvedHfModel> Function(
      String repo, {
      String? platform,
      PreferredBackend? preferredBackend,
    });

/// Resolves [repo] from [manifest] on every platform × backend hint and
/// `expect`s what must hold for any manifest, whatever it lists. Returns the
/// number of combinations checked.
///
/// Throws like any `expect` on the first violation, and the resolver's own
/// [FormatException] on a manifest it refuses. [resolve] replaces the real
/// resolver; catalog_checks_test.dart uses it to show that each expectation
/// below can fail.
Future<int> expectResolverInvariants(
  String repo,
  Map<String, dynamic> manifest, {
  ManifestResolve? resolve,
}) async {
  final resolveWith =
      resolve ??
      LitertlmManifestResolver(
        fetch: (url, headers) async => jsonEncode(manifest),
      ).resolve;
  // Before the raw reads below: a manifest the resolver refuses then fails
  // with its FormatException, which names the repo, not with a cast error
  // from here.
  await resolveWith(repo);

  final model = manifest['model'] as Map<String, dynamic>? ?? const {};
  final capabilities = model['capabilities'] as Map<String, dynamic>?;
  final thinking =
      capabilities?['thinking'] as Map<String, dynamic>? ?? const {};
  final variantsByFile = {
    for (final v in (manifest['variants'] as List).cast<Map<String, dynamic>>())
      v['file'] as String: v,
  };

  var combinations = 0;
  for (final platform in platformKeys) {
    for (final hint in backendHints) {
      combinations++;
      final r = await resolveWith(
        repo,
        platform: platform,
        preferredBackend: hint,
      );
      final where = '$repo p=$platform hint=$hint';

      // The chosen file is one of the repo's variants, addressed at the
      // repo's own /resolve/ path (encoded per segment, as core's
      // fromHuggingFace does).
      final variant = variantsByFile[r.file];
      expect(variant, isNotNull, reason: where);
      expect(
        r.url,
        'https://huggingface.co/$repo/resolve/main/'
        '${r.file.split('/').map(Uri.encodeComponent).join('/')}',
        reason: where,
      );

      // Identity comes from that same variant.
      expect(r.sha256, variant!['sha256'], reason: where);
      expect(r.sizeBytes, variant['size_bytes'], reason: where);

      // The resolved backend is always in the variant's VERIFIED list, and
      // never silently null: a backend name this plugin has no enum value
      // for fails here rather than falling back to the SDK default.
      expect(r.runtime.preferredBackend, isNotNull, reason: where);
      expect(
        (variant['backends'] as List).cast<String>(),
        contains(wireName(r.runtime.preferredBackend!)),
        reason: where,
      );

      // Spec resolution rule: a hint some variant is verified on is a
      // FILTER — the result keeps exactly that backend. A hint nothing
      // lists is dropped: the result must equal the same resolve with no
      // hint (platform preserved), never a substitute for the request.
      if (hint != null) {
        final anyListsHint = variantsByFile.values.any(
          (v) => (v['backends'] as List).contains(wireName(hint)),
        );
        if (anyListsHint) {
          expect(r.runtime.preferredBackend, hint, reason: where);
          expect(
            r.notes.where((n) => n.contains('resolved without that hint')),
            isEmpty,
            reason: where,
          );
        } else {
          final noHint = await resolveWith(repo, platform: platform);
          expect(r.file, noHint.file, reason: where);
          expect(
            r.runtime.preferredBackend,
            noHint.runtime.preferredBackend,
            reason: where,
          );
          // The drop is on the record: the no-hint notes plus one line
          // naming the dropped hint.
          expect(r.notes, [
            ...noHint.notes,
            'No variant of "$repo" is verified on the requested '
                '${wireName(hint)} backend; resolved without that hint '
                '(${wireName(r.runtime.preferredBackend!)}).',
          ], reason: where);
        }
      }

      // Model-level fields land regardless of variant choice. A manifest
      // with no `capabilities` block is silent, which the seam spells null —
      // not false.
      expect(r.runtime.maxTokens, model['context_length'], reason: where);
      expect(
        r.runtime.thinkingDeclared,
        capabilities == null ? isNull : thinking['declared'] == true,
        reason: where,
      );
      expect(
        r.runtime.supportImage,
        capabilities == null ? isNull : capabilities['vision'] == true,
        reason: where,
      );
      expect(
        r.runtime.supportAudio,
        capabilities == null ? isNull : capabilities['audio'] == true,
        reason: where,
      );
    }
  }
  return combinations;
}

/// A public repo of a listing that ships a manifest. A [gated] repo answers
/// 401 or 403 to a caller without access.
typedef ListedRepo = ({String id, bool gated});

/// The public repos in one org's model listing that ship a manifest. May be
/// empty: an org with no manifest left is a change of the catalog, not a
/// broken listing.
///
/// [body] is the answer to `/api/models?author=<org>&limit=<limit>&full=true`
/// and [linkHeader] its `Link` response header. Throws [StateError] whenever
/// the listing cannot be taken for the whole org, because every check built
/// on a short list would pass over the repos it is missing:
/// - it is not a JSON list, or it is empty;
/// - it may be cut off — it fills the page, or the header names a next page;
/// - an entry has no `siblings` list, which is how the API answers without
///   `full=true` (no file names, so nothing would look like it ships one).
///
/// Private repos are left out: a token that can see them must not change
/// what is checked, or put their names in a public log.
List<ListedRepo> reposShippingManifest(
  String body, {
  required String org,
  required int limit,
  String? linkHeader,
}) {
  final decoded = jsonDecode(body);
  if (decoded is! List) {
    throw StateError('the model listing for $org is not a JSON list');
  }
  if (decoded.isEmpty) {
    throw StateError('the model listing for $org is empty');
  }
  if (decoded.length >= limit || (linkHeader ?? '').contains('rel="next"')) {
    throw StateError(
      'the model listing for $org may be cut off: ${decoded.length} entries '
      'at limit=$limit${linkHeader == null ? '' : ', Link: $linkHeader'} — '
      'follow the pages before trusting it',
    );
  }
  final shipping = <ListedRepo>[];
  for (final entry in decoded) {
    final id = entry is Map ? entry['id'] : null;
    final siblings = entry is Map ? entry['siblings'] : null;
    if (id is! String || siblings is! List) {
      throw StateError(
        'an entry of the model listing for $org has no id or no siblings '
        'list (was it requested with full=true?): '
        '${entry is Map ? entry['id'] : entry}',
      );
    }
    if (entry['private'] == true) continue;
    if (siblings.any((s) => s is Map && s['rfilename'] == manifestFileName)) {
      // `gated` is false, "auto" or "manual".
      final gated = entry['gated'];
      shipping.add((id: id, gated: gated != null && gated != false));
    }
  }
  return shipping;
}

/// Whether [error] is Hugging Face refusing a gated repo's manifest to a
/// caller without access. That is the repo's setting, not a manifest that is
/// missing, so the live leg reports it and does not fail on it.
bool isGatedRefusal(Object error, {required bool gated}) =>
    gated &&
    error is ManifestFetchException &&
    (error.statusCode == 401 || error.statusCode == 403);

/// Where [manifest]'s advisory `sha256`/`size_bytes` disagree with the files
/// [repo] actually holds. [tree] is the answer to
/// `/api/models/<repo>/tree/main?recursive=true`. Empty when they agree.
///
/// A field the manifest does not state is not compared: the format makes
/// both optional. A file that is not in the repo is always a mismatch.
List<String> lfsMismatches(
  String repo,
  Map<String, dynamic> manifest,
  List<dynamic> tree,
) {
  final byPath = {
    for (final e in tree.cast<Map<String, dynamic>>()) e['path'] as String: e,
  };
  final mismatches = <String>[];
  for (final v in (manifest['variants'] as List).cast<Map<String, dynamic>>()) {
    final file = v['file'] as String;
    final e = byPath[file];
    if (e == null) {
      mismatches.add('$repo: $file is not in the repo tree');
      continue;
    }
    final lfs = e['lfs'] as Map<String, dynamic>? ?? const {};
    final sha = lfs['oid'];
    final size = lfs['size'] ?? e['size'];
    if (v['sha256'] != null && sha != v['sha256']) {
      mismatches.add('$repo: $file sha256 ${v['sha256']} → $sha');
    }
    if (v['size_bytes'] != null && size != v['size_bytes']) {
      mismatches.add('$repo: $file size_bytes ${v['size_bytes']} → $size');
    }
  }
  return mismatches;
}

/// How [live] (what Hugging Face serves, keyed by repo id) differs from
/// [snapshot] (the committed fixtures), as Markdown for the job summary.
/// Information only — the catalog is expected to move ahead of the snapshot —
/// so it reads both sides leniently: a manifest it cannot make sense of is
/// some other check's failure, never a throw from here.
String snapshotDifference(
  Map<String, Map<String, dynamic>> snapshot,
  Map<String, Map<String, dynamic>> live,
) {
  int variants(Iterable<Map<String, dynamic>> manifests) =>
      manifests.fold(0, (n, m) => n + _variantsByFile(m).length);

  final added = live.keys.where((r) => !snapshot.containsKey(r)).toList()
    ..sort();
  final gone = snapshot.keys.where((r) => !live.containsKey(r)).toList()
    ..sort();
  final changed = <String>[];
  for (final repo in live.keys.where(snapshot.containsKey).toList()..sort()) {
    final what = _changes(snapshot[repo]!, live[repo]!);
    if (what.isNotEmpty) changed.add('`$repo`: ${what.join('; ')}');
  }

  final out = StringBuffer()
    ..writeln('### Difference from the committed snapshot')
    ..writeln()
    ..writeln(
      'Hugging Face serves ${live.length} manifests '
      '(${variants(live.values)} variants); the snapshot holds '
      '${snapshot.length} (${variants(snapshot.values)}). None of this fails '
      'the run.',
    )
    ..writeln();
  if (added.isEmpty && gone.isEmpty && changed.isEmpty) {
    out.writeln('No difference.');
    return out.toString();
  }
  void section(String title, List<String> lines) {
    if (lines.isEmpty) return;
    out.writeln('**$title (${lines.length})**');
    out.writeln();
    for (final line in lines) {
      out.writeln('- $line');
    }
    out.writeln();
  }

  section('Served, not in the snapshot', [for (final r in added) '`$r`']);
  section('In the snapshot, no longer served', [for (final r in gone) '`$r`']);
  section('Changed since the snapshot', changed);
  return out.toString();
}

bool _same(Object? a, Object? b) => equals(a).matches(b, {});

/// A manifest's variants by file name, skipping whatever is not a variant
/// with one.
Map<String, Map<String, dynamic>> _variantsByFile(Map<String, dynamic> m) {
  final variants = m['variants'];
  return {
    if (variants is List)
      for (final v in variants.whereType<Map<String, dynamic>>())
        if (v['file'] case final String file) file: v,
  };
}

/// What moved between two manifests of one repo, coarsely: files that came,
/// went or changed identity, and which other parts differ.
List<String> _changes(Map<String, dynamic> before, Map<String, dynamic> after) {
  final was = _variantsByFile(before);
  final now = _variantsByFile(after);
  final what = <String>[
    for (final f in now.keys.where((f) => !was.containsKey(f))) '+$f',
    for (final f in was.keys.where((f) => !now.containsKey(f))) '-$f',
  ];
  for (final f in now.keys.where(was.containsKey)) {
    final identity = [
      for (final k in const ['sha256', 'size_bytes'])
        if (was[f]![k] != now[f]![k]) k,
    ];
    if (identity.isNotEmpty) {
      what.add('$f (${identity.join(', ')})');
    } else if (!_same(was[f], now[f])) {
      what.add('$f (other fields)');
    }
  }
  for (final key in {...before.keys, ...after.keys}) {
    if (key != 'variants' && !_same(before[key], after[key])) what.add(key);
  }
  // Variants this could not key by file still count as a change.
  if (what.isEmpty && !_same(before['variants'], after['variants'])) {
    what.add('variants');
  }
  return what;
}

/// The committed snapshot (fixtures/README.md), keyed by repo id. Reads the
/// package's own test directory, so run from the package root, as
/// `flutter test` does.
Map<String, Map<String, dynamic>> loadSnapshot() {
  final files =
      Directory('test/manifest/fixtures')
          .listSync()
          .whereType<File>()
          .where(
            (f) =>
                f.path.endsWith('.json') &&
                !f.path.endsWith('reference_goldens.json'),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return {
    for (final json in files.map(
      (f) => jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
    ))
      json['repo'] as String: json,
  };
}

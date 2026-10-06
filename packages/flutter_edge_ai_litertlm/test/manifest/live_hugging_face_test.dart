// The LIVE leg — opt-in, never part of the default `flutter test`:
//
//   FLUTTER_GEMMA_LIVE_HF=1 flutter test test/manifest/live_hugging_face_test.dart
//
// (add HF_TOKEN=hf_… for gated repos or a higher rate limit). Without the
// variable every test here is skipped. `.github/workflows/live-manifests.yml`
// runs it on a schedule, with `--run-skipped`.
//
// It checks every manifest the two orgs serve TODAY, not the committed
// snapshot, so a new upload does not turn it red. A red run means one of:
// - a model listing that cannot be taken for the whole org (empty, cut off,
//   or answered without file names), or no listed manifest at all — nothing
//   below can be trusted then;
// - a listed manifest that is not served, or that the resolver cannot handle
//   (the offline sweep's invariants, on every platform × backend hint);
// - a manifest whose sha256/size_bytes disagree with the repo's LFS metadata,
//   or that names a file the repo does not hold;
// - a URL the resolver builds that does not answer 200;
// - the engine-carried resolver failing end to end through
//   FlutterEdgeAi.resolveHuggingFace — the exact path an app runs;
// - Hugging Face being down or rate-limiting.
// Never "this PR broke something" — which is why it must not run on pull
// requests. The checks themselves are in catalog_checks.dart, where
// catalog_checks_test.dart hands each one the input that must fail it.
//
// Reported, not failed — to the log and the job summary:
// - how the catalog differs from the snapshot (new repos, changed manifests);
// - a gated repo that refuses this run's caller (no token, or one without
//   access): its manifest cannot be read, so it is named and left unchecked.
//
// Reproduction notes:
// - flutter_test's TestWidgetsFlutterBinding installs an HttpOverrides that
//   answers every HttpClient request with 400 and makes no network call. The
//   end-to-end test needs the binding (initialize() does), so this file
//   resets `HttpOverrides.global = null` right after initializing it — for
//   the whole file, because the override is process-global.
// - `initialize()` ends in the model manager's restore, which reads
//   shared_preferences; under `flutter test` that plugin has no host, so
//   `SharedPreferences.setMockInitialValues({})` must run first (the in-memory
//   store). This is the only suite in the package that drives `initialize()`
//   — the registration contract itself is tested in core
//   (flutter_edge_ai/test/core/registry/resolver_registration_test.dart).
// - The catalog is fetched once, by whichever test asks first, and not in a
//   setUpAll: a load that fails then fails every test by name.
@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_edge_ai/core/di/service_registry.dart';
import 'package:flutter_edge_ai/core/model.dart' show ModelFileType;
import 'package:flutter_edge_ai/core/registry/engine_registry.dart';
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver.dart'
    show ResolvedHfModel;
import 'package:flutter_edge_ai/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_edge_ai/flutter_edge_ai.dart' show FlutterEdgeAi;
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart'
    show LiteRtLmEngine;
import 'package:flutter_edge_ai_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_edge_ai_litertlm/src/manifest/manifest_fetch_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'catalog_checks.dart';

/// The orgs the hf-to-litertlm converter ships manifests to.
const _orgs = ['litert-community', 'mlboydaisuke'];

/// Page size of the model listing. reposShippingManifest refuses a listing
/// that fills it, so an org outgrowing one page fails instead of being
/// checked in part.
const _listingLimit = 1000;

final bool _enabled =
    (Platform.environment['FLUTTER_GEMMA_LIVE_HF'] ?? '').isNotEmpty;
final String? _token = switch (Platform.environment['HF_TOKEN']) {
  final t? when t.isNotEmpty => t,
  _ => null,
};
Map<String, String> get _headers => {
  if (_token != null) 'Authorization': 'Bearer $_token',
};

Future<String> _get(Uri url) => defaultManifestFetch(url, _headers);

/// GET that also hands back the `Link` header — a listing's "there is a next
/// page" signal, which the published fetcher has no reason to expose.
Future<({String body, String? link})> _getWithLink(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    _headers.forEach(request.headers.set);
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}', uri: url);
    }
    return (body: body, link: response.headers.value('link'));
  } finally {
    client.close();
  }
}

/// HEAD, following redirects (Hugging Face 302s /resolve/ to its CDN); the
/// final status is what a download would see.
Future<int> _head(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.headUrl(url);
    _headers.forEach(request.headers.set);
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close();
  }
}

LitertlmManifestResolver _resolverOver(Map<String, dynamic> manifest) =>
    LitertlmManifestResolver(
      fetch: (url, headers) async => jsonEncode(manifest),
    );

/// What Hugging Face serves right now.
class _Catalog {
  /// How many public repos of each org list a manifest.
  final Map<String, int> listed = {};

  /// Every listed manifest that was served as a JSON object, by repo id.
  final Map<String, Map<String, dynamic>> manifests = {};

  /// Listed manifests that were not: `repo: why`.
  final List<String> unserved = [];

  /// Gated repos that refused this run's caller. Named, not checked.
  final List<String> refused = [];
}

Future<_Catalog> _loadCatalog() async {
  final catalog = _Catalog();
  final repos = <ListedRepo>[];
  for (final org in _orgs) {
    final page = await _getWithLink(
      Uri.parse(
        'https://huggingface.co/api/models'
        '?author=$org&limit=$_listingLimit&full=true',
      ),
    );
    // Throws when the listing is empty, cut off, or carries no file names.
    final shipping = reposShippingManifest(
      page.body,
      org: org,
      limit: _listingLimit,
      linkHeader: page.link,
    );
    catalog.listed[org] = shipping.length;
    repos.addAll(shipping);
  }

  repos.sort((a, b) => a.id.compareTo(b.id));
  for (final repo in repos) {
    try {
      // Through the published default fetcher, following the /resolve 307.
      final manifest = jsonDecode(
        await _get(
          Uri.parse(
            'https://huggingface.co/${repo.id}/resolve/main/$manifestFileName',
          ),
        ),
      );
      if (manifest is! Map<String, dynamic>) {
        throw const FormatException('the manifest is not a JSON object');
      }
      catalog.manifests[repo.id] = manifest;
    } catch (e) {
      if (isGatedRefusal(e, gated: repo.gated)) {
        catalog.refused.add(repo.id);
      } else {
        catalog.unserved.add('${repo.id}: $e');
      }
    }
  }
  return catalog;
}

/// To the log, and to the run page when GitHub provides a summary file.
void _report(String markdown) {
  // ignore: avoid_print
  print(markdown);
  final summary = Platform.environment['GITHUB_STEP_SUMMARY'] ?? '';
  if (summary.isNotEmpty) {
    File(summary).writeAsStringSync('$markdown\n', mode: FileMode.append);
  }
}

/// One line per check on the run page — what it covered, or what failed —
/// and then the verdict. The line is written before the `expect`, so a
/// failure collected here is on the run page as well as in the log.
void _conclude(String check, String scope, List<String> failures) {
  String oneLine(String f) => f.replaceAll(RegExp(r'\s+'), ' ');
  _report(
    failures.isEmpty
        ? '- $check: $scope.'
        : '- **$check: ${failures.length} failed**, of $scope.\n'
              '${failures.map((f) => '  - ${oneLine(f)}').join('\n')}',
  );
  expect(failures, isEmpty, reason: failures.join('\n'));
}

void main() {
  // Needed by initialize() in the end-to-end test — and it installs the
  // 400-everything HttpOverrides, so clear that for every HttpClient below.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  Future<_Catalog>? loading;
  Future<_Catalog> catalog() =>
      loading ??= _loadCatalog().onError<Object>((e, stackTrace) {
        // Once, by the first test to ask; every test then fails on the same
        // error.
        _report(
          '## Live manifest check\n\n'
          '**The catalog could not be loaded, so nothing was checked:** $e\n',
        );
        Error.throwWithStackTrace(e, stackTrace);
      });

  group('live Hugging Face', () {
    test(
      'both orgs list in full, and every manifest they list is served',
      () async {
        final c = await catalog();
        final perOrg = [for (final org in _orgs) '${c.listed[org]} in `$org`'];
        _report('## Live manifest check\n\nListed: ${perOrg.join(', ')}.\n');
        if (c.refused.isNotEmpty) {
          _report(
            '- Not checked, gated and closed to this run: '
            '${c.refused.map((r) => '`$r`').join(', ')}.',
          );
        }
        _conclude(
          'Served',
          '${c.manifests.length + c.unserved.length} listed manifests',
          c.unserved,
        );
        expect(c.manifests, isNotEmpty);
      },
    );

    test('every served manifest holds the sweep\'s invariants on every '
        'platform × backend hint', () async {
      final c = await catalog();
      final failures = <String>[];
      var combinations = 0;
      for (final entry in c.manifests.entries) {
        try {
          combinations += await expectResolverInvariants(
            entry.key,
            entry.value,
          );
        } on TestFailure catch (e) {
          failures.add('${entry.key}: ${e.message}');
        } catch (e) {
          // A manifest the resolver refuses outright.
          failures.add('${entry.key}: $e');
        }
      }
      expect(c.manifests, isNotEmpty);
      final perManifest = platformKeys.length * backendHints.length;
      _conclude(
        'Invariants',
        '${c.manifests.length} manifests × $perManifest platform and '
            'backend combinations',
        failures,
      );
      expect(combinations, c.manifests.length * perManifest);
    });

    test(
      'every variant\'s sha256/size_bytes match the repo\'s LFS metadata',
      () async {
        final c = await catalog();
        final mismatches = <String>[];
        var checked = 0;
        var unstated = 0;
        for (final entry in c.manifests.entries) {
          final repo = entry.key;
          try {
            final page = await _getWithLink(
              Uri.parse(
                'https://huggingface.co/api/models/$repo/tree/main'
                '?recursive=true',
              ),
            );
            if ((page.link ?? '').contains('rel="next"')) {
              // A file past the first page would read as missing.
              mismatches.add(
                '$repo: the file tree is cut off (a next page exists), so '
                'its files were not compared',
              );
              continue;
            }
            mismatches.addAll(
              lfsMismatches(repo, entry.value, jsonDecode(page.body) as List),
            );
            final variants = (entry.value['variants'] as List)
                .cast<Map<String, dynamic>>();
            checked += variants.length;
            unstated += variants
                .where((v) => v['sha256'] == null || v['size_bytes'] == null)
                .length;
          } catch (e) {
            mismatches.add('$repo: $e');
          }
        }
        expect(checked + mismatches.length, greaterThan(0));
        final gap = unstated == 0
            ? ''
            : ' ($unstated state no sha256 or no size_bytes to compare)';
        _conclude('LFS identity', '$checked variants$gap', mismatches);
      },
    );

    test('every URL the resolver can build answers 200', () async {
      final c = await catalog();
      final urls = <String>{};
      final failures = <String>[];
      for (final entry in c.manifests.entries) {
        try {
          final resolver = _resolverOver(entry.value);
          for (final platform in platformKeys) {
            for (final hint in backendHints) {
              final r = await resolver.resolve(
                entry.key,
                platform: platform,
                preferredBackend: hint,
              );
              urls.add(r.url);
            }
          }
        } catch (e) {
          // Named here too, so one refused manifest does not hide the URLs
          // of every other repo.
          failures.add('${entry.key}: no URL to check — $e');
        }
      }
      for (final url in urls) {
        try {
          final status = await _head(Uri.parse(url));
          if (status != 200) failures.add('$url → HTTP $status');
        } catch (e) {
          failures.add('$url → $e');
        }
      }
      expect(urls.length + failures.length, greaterThan(0));
      _conclude('URLs answering 200', '${urls.length} URLs', failures);
    });

    test(
      'engine-carried resolver end to end via FlutterEdgeAi.resolveHuggingFace '
      '(published default fetcher, follows the /resolve 307)',
      () async {
        final c = await catalog();
        // The first repo whose manifest resolves: one the resolver refuses is
        // the invariants test's failure, and must not take this check with
        // it.
        String? repo;
        ResolvedHfModel? expected;
        for (final id in c.manifests.keys.toList()..sort()) {
          try {
            expected = await _resolverOver(
              c.manifests[id]!,
            ).resolve(id, platform: 'macos');
            repo = id;
            break;
          } catch (_) {
            continue;
          }
        }
        if (repo == null || expected == null) {
          _conclude('End to end', 'one repo', ['no served manifest resolves']);
          return;
        }

        SharedPreferences.setMockInitialValues({});
        ServiceRegistry.reset();
        EngineRegistry.instance.reset();
        HuggingFaceResolverRegistry.instance.reset();
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        addTearDown(() {
          debugDefaultTargetPlatformOverride = null;
          HuggingFaceResolverRegistry.instance.reset();
          EngineRegistry.instance.reset();
          ServiceRegistry.reset();
        });

        // The app path must land where the resolver lands on the manifest
        // this run already fetched and checked.
        final failures = <String>[];
        try {
          await FlutterEdgeAi.initialize(
            huggingFaceToken: _token,
            inferenceEngines: const [LiteRtLmEngine()],
          );
          final r = await FlutterEdgeAi.resolveHuggingFace(
            repo,
            fileType: ModelFileType.litertlm,
          );
          void same(String what, Object? got, Object? want) {
            if (got != want) failures.add('$what is $got, expected $want');
          }

          same('file', r.file, expected.file);
          same('url', r.url, expected.url);
          same('sha256', r.sha256, expected.sha256);
          same(
            'backend',
            r.runtime.preferredBackend,
            expected.runtime.preferredBackend,
          );
        } catch (e) {
          failures.add('$e');
        }
        _conclude('End to end', '`$repo` → `${expected.file}`', failures);
      },
    );

    test(
      'the difference from the committed snapshot is reported, not failed',
      () async {
        final c = await catalog();
        _report('\n${snapshotDifference(loadSnapshot(), c.manifests)}');
      },
    );
  }, skip: _enabled ? false : 'set FLUTTER_GEMMA_LIVE_HF=1 to run the live leg');
}

// The LIVE leg — opt-in, never part of the default `flutter test`:
//
//   FLUTTER_GEMMA_LIVE_HF=1 flutter test test/manifest/live_hugging_face_test.dart
//
// (add HF_TOKEN=hf_… for gated repos or a higher rate limit). Without the
// variable every test here is skipped. `.github/workflows/live-manifests.yml`
// runs it on a schedule; a failure there means "the catalog moved" (or Hugging
// Face is down or rate-limiting), never "this PR broke something" — which is
// why it must not run on pull requests.
//
// What it checks, against the real Hugging Face:
// - every fixture repo still serves its manifest through the published
//   default fetcher (following the /resolve 307), and the manifest IS the
//   committed snapshot — drift fails with the regeneration pointer;
// - no repo outside the snapshot ships a manifest (a new one is drift too);
// - every variant's advisory sha256/size_bytes equal the repo's LFS metadata;
// - every URL the resolver can build (all platforms × hints) answers 200;
// - the engine-carried resolver resolves end to end through
//   FlutterGemma.resolveHuggingFace — the exact path an app runs.
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
//   (flutter_gemma/test/core/registry/resolver_registration_test.dart).
@TestOn('vm')
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter_gemma/core/di/service_registry.dart';
import 'package:flutter_gemma/core/domain/platform_types.dart'
    show PreferredBackend;
import 'package:flutter_gemma/core/model.dart' show ModelFileType;
import 'package:flutter_gemma/core/registry/engine_registry.dart';
import 'package:flutter_gemma/core/registry/hugging_face_resolver_registry.dart';
import 'package:flutter_gemma/flutter_gemma.dart' show FlutterGemma;
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart'
    show LiteRtLmEngine;
import 'package:flutter_gemma_litertlm/src/manifest/litertlm_manifest_resolver.dart';
import 'package:flutter_gemma_litertlm/src/manifest/manifest_fetch_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The orgs the hf-to-litertlm converter ships manifests to. A repo here that
/// ships a manifest but is missing from the snapshot is drift.
const _orgs = ['litert-community', 'mlboydaisuke'];

const _platforms = [
  null,
  'android',
  'ios',
  'macos',
  'windows',
  'linux',
  'web',
  'unknown',
];
const _hints = [
  null,
  PreferredBackend.cpu,
  PreferredBackend.gpu,
  PreferredBackend.npu,
];

const _regenerate =
    'the catalog moved — regenerate test/manifest/fixtures (see its README.md)';

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

void main() {
  // Needed by initialize() in the end-to-end test — and it installs the
  // 400-everything HttpOverrides, so clear that for every HttpClient below.
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  final dir = Directory('test/manifest/fixtures');
  final byRepo = <String, Map<String, dynamic>>{};
  for (final f in dir.listSync().whereType<File>()) {
    if (!f.path.endsWith('.json') ||
        f.path.endsWith('reference_goldens.json')) {
      continue;
    }
    final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    byRepo[json['repo'] as String] = json;
  }
  final goldens =
      jsonDecode(
            File(
              'test/manifest/fixtures/reference_goldens.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;

  group('live Hugging Face', () {
    test(
      'every fixture repo serves the committed manifest (no drift)',
      () async {
        final drift = <String>[];
        for (final entry in byRepo.entries) {
          final repo = entry.key;
          final url = Uri.parse(
            'https://huggingface.co/$repo/resolve/main/litertlm_manifest.json',
          );
          final live = jsonDecode(await _get(url));
          if (!equals(entry.value).matches(live, {})) drift.add(repo);
        }
        expect(drift, isEmpty, reason: '$_regenerate; changed: $drift');
      },
    );

    test('no repo outside the snapshot ships a manifest', () async {
      final shipping = <String>{};
      for (final org in _orgs) {
        final url = Uri.parse(
          'https://huggingface.co/api/models?author=$org&limit=1000&full=true',
        );
        final models = (jsonDecode(await _get(url)) as List)
            .cast<Map<String, dynamic>>();
        for (final m in models) {
          final siblings = (m['siblings'] as List? ?? const [])
              .cast<Map<String, dynamic>>();
          if (siblings.any((s) => s['rfilename'] == 'litertlm_manifest.json')) {
            shipping.add(m['id'] as String);
          }
        }
      }
      final missing = shipping.difference(byRepo.keys.toSet());
      expect(missing, isEmpty, reason: '$_regenerate; new: $missing');
    });

    test(
      'every variant\'s sha256/size_bytes match the repo\'s LFS metadata',
      () async {
        final mismatches = <String>[];
        var checked = 0;
        for (final entry in byRepo.entries) {
          final repo = entry.key;
          final tree =
              (jsonDecode(
                        await _get(
                          Uri.parse(
                            'https://huggingface.co/api/models/$repo/tree/main'
                            '?recursive=true',
                          ),
                        ),
                      )
                      as List)
                  .cast<Map<String, dynamic>>();
          final byPath = {for (final e in tree) e['path'] as String: e};
          final variants = (entry.value['variants'] as List)
              .cast<Map<String, dynamic>>();
          for (final v in variants) {
            checked++;
            final file = v['file'] as String;
            final e = byPath[file];
            if (e == null) {
              mismatches.add('$repo: $file is not in the repo tree');
              continue;
            }
            final lfs = e['lfs'] as Map<String, dynamic>? ?? const {};
            final sha = lfs['oid'];
            final size = lfs['size'] ?? e['size'];
            if (sha != v['sha256']) {
              mismatches.add('$repo: $file sha256 ${v['sha256']} → $sha');
            }
            if (size != v['size_bytes']) {
              mismatches.add(
                '$repo: $file size_bytes ${v['size_bytes']} → $size',
              );
            }
          }
        }
        expect(checked, greaterThan(0));
        expect(
          mismatches,
          isEmpty,
          reason: '$_regenerate\n${mismatches.join('\n')}',
        );
      },
    );

    test('every URL the resolver can build answers 200', () async {
      final urls = <String>{};
      for (final repo in byRepo.keys) {
        final resolver = LitertlmManifestResolver(
          fetch: (url, headers) async => jsonEncode(byRepo[repo]),
        );
        for (final platform in _platforms) {
          for (final hint in _hints) {
            final r = await resolver.resolve(
              repo,
              platform: platform,
              preferredBackend: hint,
            );
            urls.add(r.url);
          }
        }
      }
      final failures = <String>[];
      for (final url in urls) {
        final status = await _head(Uri.parse(url));
        if (status != 200) failures.add('$url → HTTP $status');
      }
      expect(urls, isNotEmpty);
      expect(failures, isEmpty, reason: failures.join('\n'));
    });

    test(
      'engine-carried resolver end to end via FlutterGemma.resolveHuggingFace '
      '(published default fetcher, follows the /resolve 307)',
      () async {
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

        await FlutterGemma.initialize(
          huggingFaceToken: _token,
          inferenceEngines: const [LiteRtLmEngine()],
        );
        const repo = 'litert-community/SmolLM3-3B';
        final r = await FlutterGemma.resolveHuggingFace(
          repo,
          fileType: ModelFileType.litertlm,
        );
        final golden = goldens['$repo|macos|-'] as Map<String, dynamic>;
        expect(r.file, golden['file']);
        expect(r.runtime.preferredBackend, PreferredBackend.gpu);
        expect(golden['backend'], 'gpu');
      },
    );
  }, skip: _enabled ? false : 'set FLUTTER_GEMMA_LIVE_HF=1 to run the live leg');
}

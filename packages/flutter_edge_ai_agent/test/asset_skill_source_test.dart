import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show FlutterError;
import 'package:flutter/services.dart' show AssetBundle, ByteData;
import 'package:flutter_edge_ai_agent/flutter_edge_ai_agent.dart';
import 'package:flutter_test/flutter_test.dart';

/// A fake [AssetBundle] that resolves the package's bundled-asset keys
/// (`packages/flutter_edge_ai_agent/assets/...`) back to files on disk, so the
/// test exercises the REAL bundled SKILL.md files without a running engine.
class _DiskBundle extends AssetBundle {
  static const _prefix = 'packages/flutter_edge_ai_agent/';

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    if (!key.startsWith(_prefix)) {
      throw FlutterError('unexpected asset key: $key');
    }
    final path = key.substring(_prefix.length);
    final file = File(path);
    if (!file.existsSync()) {
      throw FlutterError('asset not found: $key');
    }
    return file.readAsString();
  }

  @override
  Future<ByteData> load(String key) async {
    final s = await loadString(key);
    return ByteData.view(Uint8List.fromList(s.codeUnits).buffer);
  }
}

/// Answers the SKILL.md of a skill in [bodies] with that text, of a skill in
/// [errors] by throwing that error, and everything else from [inner]. Records
/// every evicted key.
class _OverlayBundle extends AssetBundle {
  _OverlayBundle(this.inner, {this.bodies = const {}, this.errors = const {}});

  final AssetBundle inner;
  final Map<String, String> bodies;
  final Map<String, Object> errors;
  final evicted = <String>[];

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    for (final MapEntry(key: name, value: body) in bodies.entries) {
      if (key == AssetSkillSource.skillMdKey(name)) return body;
    }
    for (final MapEntry(key: name, value: error) in errors.entries) {
      if (key == AssetSkillSource.skillMdKey(name)) throw error;
    }
    return inner.loadString(key, cache: cache);
  }

  @override
  Future<ByteData> load(String key) => inner.load(key);

  @override
  void evict(String key) => evicted.add(key);
}

/// The [BundledSkillLoadError] that [future] throws.
Future<BundledSkillLoadError> _loadError(Future<Object?> future) async {
  try {
    await future;
  } on BundledSkillLoadError catch (e) {
    return e;
  }
  fail('load() returned instead of throwing BundledSkillLoadError');
}

void main() {
  group('AssetSkillSource — bundled starter skills', () {
    test('bundledSkillNames covers all four skill mechanisms', () {
      expect(
        bundledSkillNames,
        containsAll(<String>[
          'calculate-hash', // js
          'qr-code', // js (image)
          'query-wikipedia', // js (data)
          'interactive-map', // js (webview)
          'send-email', // intent
          'create-calendar-event', // intent
          'kitchen-adventure', // text-only persona
        ]),
      );
    });

    test('asset keys carry the package prefix', () {
      expect(
        AssetSkillSource.skillMdKey('calculate-hash'),
        'packages/flutter_edge_ai_agent/assets/skills/calculate-hash/SKILL.md',
      );
      expect(
        AssetSkillSource.scriptKey('qr-code'),
        'packages/flutter_edge_ai_agent/assets/skills/qr-code/scripts/index.html',
      );
      expect(
        AssetSkillSource.scriptKey('x', 'query.html'),
        'packages/flutter_edge_ai_agent/assets/skills/x/scripts/query.html',
      );
    });

    test(
      'load() parses every real bundled SKILL.md with correct types',
      () async {
        final source = AssetSkillSource(bundle: _DiskBundle());
        final skills = await source.load();

        expect(skills.length, bundledSkillNames.length);
        final byName = {for (final s in skills) s.name: s};

        expect(byName['calculate-hash']!.type, SkillType.js);
        expect(byName['qr-code']!.type, SkillType.js);
        expect(byName['query-wikipedia']!.type, SkillType.js);
        expect(byName['interactive-map']!.type, SkillType.js);
        expect(byName['send-email']!.type, SkillType.intent);
        expect(byName['create-calendar-event']!.type, SkillType.intent);
        expect(byName['kitchen-adventure']!.type, SkillType.textOnly);
      },
    );

    // Every published version up to 0.2.6 had no SKILL.md and load() returned
    // an empty catalog with no error, so nobody noticed. Every requested name
    // either yields a Skill or is named in the error.
    test('load() names every skill whose SKILL.md asset is missing', () async {
      final error = await _loadError(
        AssetSkillSource(
          bundle: _DiskBundle(),
          names: const ['calculate-hash', 'does-not-exist', 'also-missing'],
        ).load(),
      );

      expect(error, isA<StateError>());
      expect(error.failures.keys, ['does-not-exist', 'also-missing']);
      expect(error.message, isNot(contains('calculate-hash')));
    });

    test('load() keeps the cause and evicts the failed key', () async {
      final bundle = _OverlayBundle(
        _DiskBundle(),
        errors: {'qr-code': StateError('binding not initialized')},
      );
      final error = await _loadError(
        AssetSkillSource(
          bundle: bundle,
          names: const ['calculate-hash', 'qr-code'],
        ).load(),
      );

      expect(error.failures.keys, ['qr-code']);
      expect(error.message, contains('binding not initialized'));
      // A cached failed future would repeat this error for the rest of the
      // session, even once the cause is gone.
      expect(bundle.evicted, [AssetSkillSource.skillMdKey('qr-code')]);
    });

    // Flutter's own release/wasm web server and Firebase-style
    // `** -> /index.html` rewrites answer a missing asset with the app's page
    // and status 200, so loadString succeeds.
    test('load() reports an HTML page served for SKILL.md', () async {
      final error = await _loadError(
        AssetSkillSource(
          bundle: _OverlayBundle(
            _DiskBundle(),
            bodies: {
              'qr-code':
                  '<!DOCTYPE html>\n<html><head><title>app</title></head></html>',
            },
          ),
          names: const ['calculate-hash', 'qr-code'],
        ).load(),
      );

      expect(error.failures.keys, ['qr-code']);
      expect(error.failures['qr-code'], contains('HTML page'));
    });

    // What the HTML check does not recognise still fails: a page with a
    // leading comment, a plain-text 404 body, a TypeError from the parser.
    test('load() names a SKILL.md that loads but does not parse', () async {
      final error = await _loadError(
        AssetSkillSource(
          bundle: _OverlayBundle(
            _DiskBundle(),
            bodies: {
              'qr-code': '<!-- licence -->\n<!DOCTYPE html><html></html>',
              'send-email': 'Not Found',
            },
          ),
          names: const ['calculate-hash', 'qr-code', 'send-email'],
        ).load(),
      );

      expect(error.failures.keys, ['qr-code', 'send-email']);
    });

    test(
      'load() names a skill whose frontmatter name is not its directory',
      () async {
        final error = await _loadError(
          AssetSkillSource(
            bundle: _OverlayBundle(
              _DiskBundle(),
              bodies: {
                'qr-code': '---\nname: qr_code\ndescription: QR\n---\nrun_js',
              },
            ),
            names: const ['calculate-hash', 'qr-code'],
          ).load(),
        );

        expect(error.failures.keys, ['qr-code']);
        expect(error.failures['qr-code'], contains('qr_code'));
      },
    );

    test('jsSkillSourceFor maps a JS skill to its bundled HTML asset', () {
      final source = AssetSkillSource(bundle: _DiskBundle());
      const skill = Skill(
        name: 'interactive-map',
        description: 'map',
        instructions: 'run_js',
        type: SkillType.js,
      );

      final jsSource = source.jsSkillSourceFor(skill);
      expect(jsSource, isA<AssetJsSource>());
      expect(
        (jsSource as AssetJsSource).assetKey,
        'packages/flutter_edge_ai_agent/assets/skills/'
        'interactive-map/scripts/index.html',
      );
    });

    test('every JS bundled skill ships a runnable scripts/ dir keeping the '
        'Gallery contract', () {
      for (final name in [
        'calculate-hash', // defines the contract in scripts/index.js
        'qr-code',
        'query-wikipedia',
        'interactive-map',
      ]) {
        final entry = File('assets/skills/$name/scripts/index.html');
        expect(entry.existsSync(), isTrue, reason: 'missing index.html: $name');

        // The Gallery global may live in index.html or a loaded index.js;
        // assert it appears somewhere in the skill's scripts/ directory.
        final defined = Directory('assets/skills/$name/scripts')
            .listSync()
            .whereType<File>()
            .any(
              (f) =>
                  f.readAsStringSync().contains('ai_edge_gallery_get_result'),
            );
        expect(
          defined,
          isTrue,
          reason: '$name must keep the Gallery JS contract',
        );
      }
    });
  });
}

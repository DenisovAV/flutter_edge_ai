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

/// Serves [body] (text with no frontmatter by default) as the SKILL.md of the
/// [malformed] skills, everything else from [inner].
class _MalformedOverlayBundle extends AssetBundle {
  _MalformedOverlayBundle(
    this.inner,
    this.malformed, {
    this.body = 'not a skill: no frontmatter',
  });

  final AssetBundle inner;
  final Set<String> malformed;
  final String body;

  @override
  Future<String> loadString(String key, {bool cache = true}) {
    for (final name in malformed) {
      if (key == AssetSkillSource.skillMdKey(name)) {
        return Future.value(body);
      }
    }
    return inner.loadString(key, cache: cache);
  }

  @override
  Future<ByteData> load(String key) => inner.load(key);
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

    // 0.2.6 was published without any SKILL.md and load() returned an empty
    // catalog with no error, so nobody noticed. A missing asset must say so.
    test('load() names every skill whose SKILL.md asset is missing', () async {
      final source = AssetSkillSource(
        bundle: _DiskBundle(),
        names: const ['calculate-hash', 'does-not-exist', 'also-missing'],
      );

      await expectLater(
        source.load(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('does-not-exist'),
              contains('also-missing'),
              isNot(contains('calculate-hash')),
            ),
          ),
        ),
      );
    });

    // Firebase-style `** -> /index.html` rewrites answer a missing asset with
    // the app's page and status 200, so loadString succeeds.
    test('load() treats an HTML page served for SKILL.md as missing', () async {
      final source = AssetSkillSource(
        bundle: _MalformedOverlayBundle(
          _DiskBundle(),
          {'qr-code'},
          body: '<!DOCTYPE html>\n<html><head><title>app</title></head></html>',
        ),
        names: const ['calculate-hash', 'qr-code'],
      );

      await expectLater(
        source.load(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('qr-code'),
          ),
        ),
      );
    });

    test(
      'load() still skips a SKILL.md that loads but fails to parse',
      () async {
        final source = AssetSkillSource(
          bundle: _MalformedOverlayBundle(_DiskBundle(), {'qr-code'}),
          names: const ['calculate-hash', 'qr-code'],
        );
        final skills = await source.load();

        expect(skills.map((s) => s.name), ['calculate-hash']);
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

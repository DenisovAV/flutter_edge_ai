// The `@litert-lm/core` version lives in one place,
// `liteRtLmWebRuntimeVersion`: the web arm is written and measured against
// it, and its messages quote it. The pages and the setup snippets this
// repository ships must import exactly that version, or an app copies a
// loader for a runtime the package was never run on.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:litertlm_dart/internal.dart';
import 'package:test/test.dart';

/// Files that carry the module script or its version, relative to this
/// package. The codelabs and the website run the published packages and move
/// with a release.
const _carriers = [
  'README.md',
  '../flutter_edge_ai_litertlm/README.md',
  '../flutter_edge_ai/example/web/index.html',
  '../genkit_flutter_edge_ai/example/web/index.html',
  '../flutter_edge_ai/skills/flutter-edge-ai-inference/references/platform-setup.md',
];

/// Files that speak of the runtime without a module script: any version
/// they name as the current one must be the pinned one (history is written
/// without the `@litert-lm/core 0.x` form).
const _prose = ['../flutter_edge_ai/skills/flutter-edge-ai-rag/SKILL.md'];

/// `@litert-lm/core` with a version, however it is written: a URL
/// (`@litert-lm/core@0.18.0/+esm`), an `npm i @litert-lm/core@0.18.0`, a
/// prose `@litert-lm/core` 0.18.0 or `@litert-lm/core 0.18.0`.
final _pin = RegExp(r'@litert-lm/core(?:@|`? )(\d+\.\d+\.\d+)');

void main() {
  test('the module URL is the pinned version on jsDelivr', () {
    expect(
      liteRtLmWebModuleUrl,
      'https://cdn.jsdelivr.net/npm/@litert-lm/core@'
      '$liteRtLmWebRuntimeVersion/+esm',
    );
  });

  for (final path in _carriers) {
    test('$path imports @litert-lm/core $liteRtLmWebRuntimeVersion', () {
      final text = File(path).readAsStringSync();
      final pins = _pin.allMatches(text).map((m) => m.group(1)).toList();
      expect(pins, isNotEmpty, reason: '$path names no version any more');
      expect(pins, everyElement(liteRtLmWebRuntimeVersion));
    });
  }

  for (final path in _prose) {
    test('$path names no @litert-lm/core but $liteRtLmWebRuntimeVersion', () {
      final pins = _pin.allMatches(File(path).readAsStringSync());
      expect(
        pins.map((m) => m.group(1)),
        everyElement(liteRtLmWebRuntimeVersion),
      );
    });
  }

  // The web EG2 suites compare against frozen goldens of the LiteRT-LM
  // release the page runs (integration_test/goldens/*_web.dart), or a drift
  // between releases reads as a fault. Moving the pin means new goldens.
  String majorMinor(String v) => v.split('.').take(2).join('.');
  Map<String, Object?> webGolden(String file) {
    final source = File(
      '../flutter_edge_ai/example/integration_test/goldens/$file',
    ).readAsStringSync();
    final start = source.indexOf("r'''") + 4;
    return jsonDecode(source.substring(start, source.indexOf("'''", start)))
        as Map<String, Object?>;
  }

  test('eg2_audio_golden_web.dart comes from LiteRT-LM '
      '$liteRtLmWebRuntimeVersion\'s major.minor', () {
    final runtime =
        (webGolden('eg2_audio_golden_web.dart')['runtime']! as Map)['litert-lm']
            as String;
    expect(majorMinor(runtime), majorMinor(liteRtLmWebRuntimeVersion));
  });

  test('eg2_text_golden_web.dart comes from a native build of LiteRT-LM '
      '$liteRtLmWebRuntimeVersion\'s major.minor', () {
    final tag =
        (webGolden('eg2_text_golden_web.dart')['native_library']! as Map)['tag']
            as String;
    expect(
      tag,
      startsWith('native-v${majorMinor(liteRtLmWebRuntimeVersion)}.'),
    );
  });
}

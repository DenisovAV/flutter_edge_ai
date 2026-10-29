// The generated speech catalog: where each variant runs, that every TTS
// bundle is the files core's installer fetches, and a snapshot for the
// website (model_registry/snapshots/flutter_edge_ai_speech.json; write it with
// UPDATE_GOLDENS=1 flutter test test/catalog/speech_catalog_test.dart).

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — the TTS manifest and fetch rules the catalog must match are core-internal.
import 'package:flutter_edge_ai/src/model_management/model_specs.dart'
    show TtsAbsoluteUrl, TtsModelTypeManifest, TtsRelativeSuffix;
import 'package:flutter_edge_ai_speech/flutter_edge_ai_speech.dart';
import 'package:flutter_edge_ai_speech/src/catalog/speech_catalog.dart'
    show debugSpeechCatalogAbi, debugSpeechCatalogOnWeb;
import 'package:flutter_test/flutter_test.dart';

T _on<T>(bool web, T Function() read, {String abi = 'macos_arm64'}) {
  debugSpeechCatalogOnWeb = web;
  debugSpeechCatalogAbi = abi;
  try {
    return read();
  } finally {
    debugSpeechCatalogOnWeb = null;
    debugSpeechCatalogAbi = null;
  }
}

const _native = {PreferredBackend.cpu, PreferredBackend.gpu};

void main() {
  group('where a speech model runs', () {
    final moonshine = LiteRtSpeechModels.moonshineTiny;

    test('natively on the CPU or the GPU; nothing on the web', () {
      expect(_on(false, () => moonshine.f32.backendsHere), _native);
      expect(_on(true, () => moonshine.f32.backendsHere), isEmpty);
      expect(
        _on(false, () => LiteRtSpeechModels.qwen3Tts0_6b.bundle.backendsHere),
        _native,
      );
    });

    test('nothing on a host the native archive is not published for', () {
      for (final abi in ['windows_arm64', 'macos_x64', 'android_x64']) {
        expect(_on(false, () => moonshine.f32.backendsHere, abi: abi), isEmpty);
      }
    });

    test('the native hosts are flutter_edge_ai_litertlm\'s', () {
      final source = File(
        '../flutter_edge_ai_litertlm/lib/src/native_hosts.dart',
      ).readAsStringSync();
      final table = RegExp(
        r'const liteRtLmNativeAbis = \{([^}]*)\}',
      ).firstMatch(source)!.group(1)!;
      final theirs = {
        for (final m in RegExp(r"'(\w+)'").allMatches(table)) m.group(1)!,
      };
      for (final abi in theirs) {
        expect(
          _on(false, () => moonshine.f32.backendsHere, abi: abi),
          _native,
          reason: abi,
        );
      }
      expect(theirs, hasLength(6));
    });

    test('a file compiled for an NPU runs nowhere in this version', () {
      expect(_on(false, () => moonshine.f32NpuSm8750.backendsHere), isEmpty);
    });

    test('variantFor picks the first file that is not an NPU build', () {
      expect(_on(false, moonshine.variantFor), same(moonshine.f32));
    });
  });

  test('every TTS bundle is the files core installs, at the pinned URLs', () {
    for (final model in LiteRtSpeechModels.tts) {
      for (final v in model.variants) {
        final manifest = v.type.manifest;
        expect(
          v.files.map((f) => f.installFilename),
          manifest,
          reason: '${v.id}: files in TtsModelType.manifest order',
        );
        for (final (i, name) in manifest.indexed) {
          final url = switch (v.type.fetchLocationFor(name)) {
            TtsRelativeSuffix(:final suffix) => '${v.baseUrl}$suffix',
            TtsAbsoluteUrl(:final url) => url,
          };
          expect(url, v.files[i].url, reason: '${v.id}: $name');
        }
      }
    }
  });

  test('the snapshot of every variant natively and on the web', () {
    final snapshot = <String, Object?>{
      for (final variant in [
        for (final m in LiteRtSpeechModels.stt) ...m.variants,
        for (final m in LiteRtSpeechModels.tts) ...m.variants,
      ])
        variant.id: {
          for (final (host, web) in const [
            ('android_arm64', false),
            ('ios_arm64', false),
            ('macos_arm64', false),
            ('linux_x64', false),
            ('linux_arm64', false),
            ('windows_x64', false),
            ('web', true),
          ])
            host: [
              for (final b in PreferredBackend.values)
                if (_on(web, () => variant.backendsHere, abi: host).contains(b))
                  b.name,
            ],
        },
    };
    final actual =
        '${const JsonEncoder.withIndent('  ').convert({'package': 'flutter_edge_ai_speech', 'backends_here': snapshot})}\n';
    final golden = File(
      '../../model_registry/snapshots/flutter_edge_ai_speech.json',
    );
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      // A snapshot written on CI would pass whatever the change did to it.
      if ((Platform.environment['CI'] ?? '').isNotEmpty) {
        fail('UPDATE_GOLDENS=1 is refused while CI is set');
      }
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync(actual);
      return;
    }
    expect(actual, golden.readAsStringSync());
  });
}

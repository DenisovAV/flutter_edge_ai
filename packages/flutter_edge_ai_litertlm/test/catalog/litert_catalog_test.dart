// The generated catalog: where each variant runs on each host, checked
// against the loader's own rules, and recorded for the website.
//
// model_registry/snapshots/flutter_edge_ai_litertlm.json is every variant's
// backendsHere on every host. A change to the NPU vendor table or to the
// registry shows up as a diff of it; write it with
//   UPDATE_GOLDENS=1 flutter test test/catalog/litert_catalog_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_edge_ai_litertlm/src/bundle/litertlm_load_plan.dart'
    show textBackendsAllowedForTesting;
import 'package:flutter_edge_ai_litertlm/src/catalog/litert_catalog.dart'
    show debugLiteRtCatalogHost;
import 'package:flutter_test/flutter_test.dart';

/// Every host the website shows, `Abi.current()` spelling; null is the web.
const _hosts = <String, String?>{
  'android_arm64': 'android_arm64',
  'ios_arm64': 'ios_arm64',
  'macos_arm64': 'macos_arm64',
  'linux_x64': 'linux_x64',
  'linux_arm64': 'linux_arm64',
  'windows_x64': 'windows_x64',
  'web': null,
};

/// Backends a release withholds from a variant the loader would run.
const _withheld = <String, Set<PreferredBackend>>{
  'translategemma-4b-it/int4': {PreferredBackend.gpu},
  'translategemma-4b-it/int8': {PreferredBackend.gpu},
  'translategemma-4b-it/int4-multimodal': {PreferredBackend.gpu},
};

const _registry = '../../model_registry';

T _on<T>(String? abi, T Function() read) {
  debugLiteRtCatalogHost = () => abi;
  try {
    return read();
  } finally {
    debugLiteRtCatalogHost = null;
  }
}

Set<PreferredBackend> _here(CatalogVariant v, String? abi) =>
    _on(abi, () => v.backendsHere);

const _cpu = {PreferredBackend.cpu};
const _npu = {PreferredBackend.npu};
const _gpu = {PreferredBackend.gpu};
const _none = <PreferredBackend>{};

void main() {
  group('where an LLM runs', () {
    final gemma = LiteRtLmModels.gemma4E2bIt;

    test('a generic file runs natively on what its text model allows', () {
      expect(_here(gemma.generic, 'macos_arm64'), {
        PreferredBackend.gpu,
        PreferredBackend.cpu,
      });
      expect(_here(gemma.generic, null), _none);
    });

    test('a web bundle runs on the web only, on the GPU', () {
      expect(_here(gemma.web, null), _gpu);
      expect(_here(gemma.web, 'android_arm64'), _none);
    });

    test('an NPU build runs where its vendor\'s dispatch ships', () {
      expect(_here(gemma.npuSm8750, 'android_arm64'), _npu);
      expect(_here(gemma.npuSm8750, 'linux_arm64'), _npu);
      expect(_here(gemma.npuSm8750, 'windows_x64'), _none);
      expect(_here(gemma.npuTensorG6, 'android_arm64'), _npu);
      expect(_here(gemma.npuTensorG6, 'linux_arm64'), _none);
      expect(_here(gemma.npuPtl, 'windows_x64'), _npu);
      expect(_here(gemma.npuPtl, 'android_arm64'), _none);
    });

    test('MediaTek builds run nowhere: this package has no dispatch', () {
      for (final abi in _hosts.values) {
        expect(_here(LiteRtLmModels.qwen3_0_6b.npuMt6993, abi), _none);
      }
    });

    test('a withheld backend is not offered', () {
      expect(
        _here(LiteRtLmModels.translategemma4bIt.int4, 'macos_arm64'),
        _cpu,
      );
    });

    test('a withheld variant is not in the catalog', () {
      expect(
        LiteRtLmModels.qwen3_0_6b.variants.map((v) => v.id),
        isNot(contains('qwen3-0.6b/standard')),
      );
    });
  });

  group('where an embedder runs', () {
    final eg2 = LiteRtEmbedders.embeddinggemma2Text270m;
    final eg1 = LiteRtEmbedders.embeddinggemma300m;

    test('an EmbeddingGemma 2 bundle: CPU natively, WebGPU on the web', () {
      expect(_here(eg2.generic, 'android_arm64'), _cpu);
      expect(_here(eg2.generic, null), _gpu);
      expect(_here(eg2.npuSm8850, 'android_arm64'), _npu);
      expect(_here(eg2.npuSm8850, null), _none);
      expect(_here(eg2.npuMt6991, 'android_arm64'), _none);
    });

    test('a .tflite model: CPU natively, never an NPU build', () {
      expect(_here(eg1.seq256, 'android_arm64'), _cpu);
      expect(_here(eg1.seq256, null), {
        PreferredBackend.cpu,
        PreferredBackend.gpu,
      });
      expect(_here(eg1.seq256NpuSm8550, 'android_arm64'), _none);
    });
  });

  group('LiteRtLmNpuTarget names the vendor as core does', () {
    test('every stamp a published bundle carries', () {
      NpuVendor? of(String stamp) =>
          LiteRtLmNpuTarget(vendor: stamp, soc: 'x').npuVendor;
      expect(of('Qualcomm'), NpuVendor.qualcomm);
      expect(of('Google'), NpuVendor.googleTensor);
      expect(of('MediaTek'), NpuVendor.mediatek);
      expect(of('IntelOpenVINO'), NpuVendor.intel);
      expect(of('Acme'), isNull);
    });
  });

  group('variantFor on the generated catalog', () {
    final gemma = LiteRtLmModels.gemma4E2bIt;

    test('natively the generic file, on the web the web bundle', () {
      expect(_on('macos_arm64', gemma.variantFor), same(gemma.generic));
      expect(_on(null, gemma.variantFor), same(gemma.web));
    });

    test('the NPU build for the device SoC', () {
      expect(
        _on(
          'android_arm64',
          () => gemma.variantFor(
            npu: const LiteRtLmNpuTarget(vendor: 'Google', soc: 'Tensor_G6'),
          ),
        ),
        same(gemma.npuTensorG6),
      );
    });
  });

  test('every variant agrees with the loader on its text backends', () {
    for (final model in LiteRtLmModels.all) {
      for (final v in model.variants) {
        if (v.isWebBundle) continue;
        final info = _bundleInfo(v.file.sha256);
        final allowed = textBackendsAllowedForTesting(
          info,
        ).difference(_withheld[v.id] ?? const {});
        if (v.npuTarget == null) {
          expect(_here(v, 'macos_arm64'), allowed, reason: v.id);
        } else {
          expect(
            allowed,
            _npu,
            reason: '${v.id}: the loader runs it on the NPU',
          );
        }
      }
    }
  });

  test('the snapshot of every variant on every host', () {
    final snapshot = <String, Object?>{
      for (final variant in [
        for (final m in LiteRtLmModels.all) ...m.variants,
        for (final m in LiteRtEmbedders.all) ...m.variants,
      ])
        variant.id: {
          for (final MapEntry(key: host, value: abi) in _hosts.entries)
            host: [
              for (final b in PreferredBackend.values)
                if (_here(variant, abi).contains(b)) b.name,
            ],
        },
    };
    final actual =
        '${const JsonEncoder.withIndent('  ').convert({'package': 'flutter_edge_ai_litertlm', 'backends_here': snapshot})}\n';
    final golden = File('$_registry/snapshots/flutter_edge_ai_litertlm.json');
    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      golden
        ..createSync(recursive: true)
        ..writeAsStringSync(actual);
      return;
    }
    expect(
      actual,
      golden.readAsStringSync(),
      reason:
          'Where a variant runs changed. If that is intended, write the '
          'snapshot with UPDATE_GOLDENS=1 and commit it with the change.',
    );
  });
}

/// The bundle as the loader would read it, from the facts
/// inspect_bundle_test.dart read from its bytes.
LiteRtLmBundleInfo _bundleInfo(String sha256) {
  final facts =
      jsonDecode(File('$_registry/derived/$sha256.json').readAsStringSync())
          as Map<String, Object?>;
  LiteRtLmNpuTarget? target(Object? stamp) {
    if (stamp is! String) return null;
    final slash = stamp.indexOf('/');
    return LiteRtLmNpuTarget(
      vendor: stamp.substring(0, slash),
      soc: stamp.substring(slash + 1),
    );
  }

  final sections = [
    for (final s in (facts['sections'] as List? ?? const []))
      if (s case final Map<String, Object?> section)
        LiteRtLmSection(
          dataType: section['data_type']! as String,
          begin: 0,
          end: section['length']! as int,
          items: {...(section['items'] as Map<String, Object?>? ?? const {})},
          npuTarget: target(section['npu_target']),
        ),
  ];
  return LiteRtLmBundleInfo(
    majorVersion: 1,
    minorVersion: 0,
    patchVersion: 0,
    systemMetadata: const {},
    sections: sections,
    fileLength: facts['size']! as int,
  );
}

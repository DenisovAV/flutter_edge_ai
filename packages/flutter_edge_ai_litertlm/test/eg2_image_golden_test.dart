// The EmbeddingGemma 2 IMAGE golden: the 440m bundle's vectors for the
// example's ten generated scenes (example/assets/eg2_vision/<scene>.png, 140
// vision tokens per image), computed by THIS package's native pass on the real
// libLiteRtLm (native-v0.18.0-d, macOS arm64, CPU) — the image counterpart of
// the text golden — and the same pass's text vectors of each scene's caption
// (TaskType.none, as the example's text-to-image search sends them). The web
// drive suite (example/integration_test/web_eg2_test.dart) holds the
// browser's WebGPU image vectors to it, and searches across platforms: web
// captions against these native images, these native captions against the
// web images.
//
// Opt-in, skipped unless the host libLiteRtLm is in the download cache and
// EG2_440M_LITERTLM points at the pinned 440m bundle (revision e301f74d,
// sha256 92dcbea1…2eb0):
//   EG2_440M_LITERTLM=… flutter test test/eg2_image_golden_test.dart
// checks the committed golden (cos >= 0.9999 on macOS arm64); with
// UPDATE_GOLDENS=1 it rewrites it (refused when CI is set).

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai/engine_io.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

const _images = '../flutter_edge_ai/example/assets/eg2_vision';
const _goldenPath =
    '../flutter_edge_ai/example/integration_test/goldens/eg2_image_golden.dart';

/// The pinned 440m bundle.
const _bundleSha256 =
    '92dcbea108899e5d6e30d919b0744f90d9967e80c67a4ab5503ac16d54f62eb0';

/// The example's `eg2VisionSampleCaptions`, scene for scene (that file is the
/// example app's; the web suite checks the golden's captions against it).
const _captions = {
  'circle': 'a red circle on a white background',
  'square': 'a blue square on a white background',
  'triangle': 'a green triangle on a white background',
  'bar_chart': 'a bar chart of quarterly revenue',
  'pie_chart': 'a pie chart showing market share',
  'line_chart': 'a line chart of temperature by month',
  'grocery_receipt':
      'a grocery store receipt listing milk, bread, eggs and apples',
  'taxi_receipt': 'a taxi receipt with an airport fee',
  'stop_sign': 'a red stop sign',
  'house_scene': 'a small house on green grass under a yellow sun',
};

/// The ten scenes, in the order of the example's `eg2VisionSampleCaptions`.
const _scenes = [
  'circle',
  'square',
  'triangle',
  'bar_chart',
  'pie_chart',
  'line_chart',
  'grocery_receipt',
  'taxi_receipt',
  'stop_sign',
  'house_scene',
];

String? _env(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

String _f32(List<double> vector) {
  final bytes = ByteData(vector.length * 4);
  for (var i = 0; i < vector.length; i++) {
    bytes.setFloat32(i * 4, vector[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

List<double> _fromF32(String encoded) {
  final bytes = ByteData.sublistView(base64.decode(encoded));
  return [
    for (var i = 0; i < bytes.lengthInBytes ~/ 4; i++)
      bytes.getFloat32(i * 4, Endian.little),
  ];
}

double _cos(List<double> a, List<double> b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  return dot / (math.sqrt(na) * math.sqrt(nb));
}

/// The JSON inside the committed `.dart` golden (`r'''…'''`).
Map<String, dynamic> _readGolden() {
  final source = File(_goldenPath).readAsStringSync();
  final start = source.indexOf("r'''") + 4;
  final end = source.lastIndexOf("'''");
  return jsonDecode(source.substring(start, end)) as Map<String, dynamic>;
}

void main() {
  final dylib = firstExistingPath(
    hostNativeLibraryCandidates(
      libFileName: hostNativeLibraryFileName('LiteRtLm'),
    ),
  );
  final bundle = _env('EG2_440M_LITERTLM');
  final skip = dylib == null
      ? 'no host libLiteRtLm in the download cache'
      : bundle == null
      ? 'EG2_440M_LITERTLM is not set'
      : null;

  test('the 440m image golden: ten scenes at 140 tokens per image, and their '
      'captions', () async {
    final bundleDigest = sha256
        .convert(File(bundle!).readAsBytesSync())
        .toString();
    expect(bundleDigest, _bundleSha256, reason: 'not the pinned 440m bundle');
    final cache = Directory.systemTemp.createTempSync('eg2_image_golden_');
    final pass = LiteRtLmEmbeddingPass(
      LiteRtLmEmbeddingConfig(
        modelPath: bundle,
        cacheBase: cache.path,
        declaredMedia: {EmbeddingModality.image},
      ),
      openBindings: () =>
          bindLiteRtLmEmbeddings(DynamicLibrary.open(dylib!), label: dylib),
    );
    final vectors = <String, List<double>>{};
    final captions = <String, List<double>>{};
    try {
      await pass.load();
      for (final scene in _scenes) {
        vectors[scene] = await pass.embed(
          EmbeddingInput.image(File('$_images/$scene.png').readAsBytesSync()),
          TaskType.retrievalDocument,
        );
        captions[scene] = await pass.embed(
          EmbeddingInput.text(_captions[scene]!),
          TaskType.none,
        );
      }
    } finally {
      await pass.close();
      cache.deleteSync(recursive: true);
    }

    if (Platform.environment['UPDATE_GOLDENS'] == '1') {
      if (Platform.environment['CI'] != null) {
        fail('UPDATE_GOLDENS is refused on CI: goldens are written by hand');
      }
      final dylibDigest = sha256
          .convert(File(dylib!).readAsBytesSync())
          .toString();
      final json = const JsonEncoder.withIndent('  ').convert({
        'description':
            'EmbeddingGemma 2 440m image vectors of the example\'s ten '
            'generated scenes (assets/eg2_vision/<scene>.png), 140 vision '
            'tokens per image, and the text vectors of their captions '
            '(TaskType.none: no prefix), from flutter_edge_ai_litertlm\'s '
            'native pass on native-v0.18.0-d libLiteRtLm (macOS arm64, CPU). '
            'Written by packages/flutter_edge_ai_litertlm/test/'
            'eg2_image_golden_test.dart (UPDATE_GOLDENS=1). Vectors are '
            'base64 little-endian float32.',
        'bundle':
            'litert-community/embeddinggemma-2-text-vision-440m-litert-lm/'
            'embeddinggemma-2-text-vision-440m.litertlm',
        'bundle_revision': 'e301f74d5551b0c2641bd5cb4652a76239d5c5f8',
        'bundle_sha256': _bundleSha256,
        'native_library': {
          'tag': 'native-v0.18.0-d',
          'host': '${Abi.current()}',
          'dylib_sha256': dylibDigest,
        },
        'vision_tokens_per_image': 140,
        'images': {
          for (final scene in _scenes)
            scene: {
              'png_sha256': sha256
                  .convert(File('$_images/$scene.png').readAsBytesSync())
                  .toString(),
              'vector_f32le': _f32(vectors[scene]!),
            },
        },
        'captions': {
          for (final scene in _scenes)
            scene: {
              'text': _captions[scene],
              'task_type': 'none',
              'vector_f32le': _f32(captions[scene]!),
            },
        },
      });
      File(_goldenPath).writeAsStringSync(
        '// GENERATED by packages/flutter_edge_ai_litertlm/test/'
        'eg2_image_golden_test.dart — do\n'
        '// not edit. Regenerate: UPDATE_GOLDENS=1 EG2_440M_LITERTLM=<the '
        'pinned 440m>\n'
        '// flutter test test/eg2_image_golden_test.dart (in that package).\n'
        '//\n'
        '// EmbeddingGemma 2 image golden for integration_test/'
        'web_eg2_test.dart.\n'
        'library;\n\n'
        "const eg2ImageGoldenJson = r'''\n$json\n''';\n",
      );
      return;
    }

    final golden = _readGolden();
    final images = (golden['images'] as Map).cast<String, dynamic>();
    expect(images.keys, _scenes);
    var worst = 1.0;
    for (final scene in _scenes) {
      final entry = (images[scene] as Map).cast<String, dynamic>();
      expect(
        entry['png_sha256'],
        sha256
            .convert(File('$_images/$scene.png').readAsBytesSync())
            .toString(),
        reason: '$scene.png changed since the golden was written',
      );
      worst = math.min(
        worst,
        _cos(vectors[scene]!, _fromF32(entry['vector_f32le'] as String)),
      );
    }
    final goldenCaptions = (golden['captions'] as Map).cast<String, dynamic>();
    expect(goldenCaptions.keys, _scenes);
    for (final scene in _scenes) {
      final entry = (goldenCaptions[scene] as Map).cast<String, dynamic>();
      expect(entry['text'], _captions[scene]);
      worst = math.min(
        worst,
        _cos(captions[scene]!, _fromF32(entry['vector_f32le'] as String)),
      );
    }
    // ignore: avoid_print
    print('[eg2-image-golden] min cos vs the committed golden: $worst');
    expect(
      worst,
      greaterThanOrEqualTo(Abi.current() == Abi.macosArm64 ? 0.9999 : 0.998),
    );
  }, skip: skip);
}

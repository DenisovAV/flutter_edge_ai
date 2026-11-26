// EmbeddingGemma 2 on a real bundle, through the public API (opt-in): the
// per-request EmbeddingOptions (Kotlin's and Swift's), and the engine's
// maxInputLength and activationDataType.
//
//   EG2_270M_LITERTLM   embeddinggemma-2-text-270m.litertlm
//   EG2_440M_LITERTLM   embeddinggemma-2-text-vision-440m.litertlm (images)
//   EG2_IMAGE           a JPEG or PNG for the 440m's image checks
//   EG2_CACHE_DIR       where the engine keeps its weight caches
//   LITERTLM_EG2_BACKEND  cpu (default) or gpu
//
// Every check prints what it measured, for the record.
@TestOn('vm')
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

String? _file(String name) {
  final value = Platform.environment[name];
  return value != null && value.isNotEmpty && File(value).existsSync()
      ? value
      : null;
}

double _norm(List<double> v) =>
    math.sqrt(v.fold<double>(0, (sum, x) => sum + x * x));

List<double> _normalized(List<double> v) {
  final n = _norm(v);
  return [for (final x in v) x / n];
}

double _maxAbsDiff(List<double> a, List<double> b) {
  expect(a.length, b.length);
  var max = 0.0;
  for (var i = 0; i < a.length; i++) {
    max = math.max(max, (a[i] - b[i]).abs());
  }
  return max;
}

double _cos(List<double> a, List<double> b) {
  var dot = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
  }
  return dot / (_norm(a) * _norm(b));
}

const _text = 'task: search result | query: how do plants make food?';

void main() {
  final model270m = _file('EG2_270M_LITERTLM');
  final model440m = _file('EG2_440M_LITERTLM');
  final image = _file('EG2_IMAGE');
  final cacheDir =
      Platform.environment['EG2_CACHE_DIR'] ??
      '${Directory.systemTemp.path}/eg2_options_cache';
  final gpu = Platform.environment['LITERTLM_EG2_BACKEND'] == 'gpu';
  final backend = gpu ? const Backend.gpu() : const Backend.cpu();
  final tag = gpu ? 'gpu' : 'cpu';

  Future<EmbeddingEngine> open(
    String model, {
    int? maxInputLength,
    ActivationDataType? activationDataType,
    Backend? visionBackend,
    int? visionTokensPerImage,
  }) async {
    Directory(cacheDir).createSync(recursive: true);
    final engine = await EmbeddingEngine.create(
      EmbeddingEngineConfig(
        modelPath: model,
        cacheDir: cacheDir,
        backend: backend,
        maxInputLength: maxInputLength,
        activationDataType: activationDataType,
        visionBackend: visionBackend,
        visionTokensPerImage: visionTokensPerImage,
      ),
    );
    addTearDown(engine.close);
    return engine;
  }

  group('270m ($tag)', skip: model270m == null ? 'EG2_270M_LITERTLM' : null, () {
    test('outputSize is the first values renormalised; normalize false is '
        'the raw vector', () async {
      final engine = await open(model270m!);
      final dim = engine.info.dimension;
      final full = await engine.computeEmbedding([const Content.text(_text)]);
      final raw = await engine.computeEmbedding([
        const Content.text(_text),
      ], options: const EmbeddingOptions(normalize: false));
      final cut = await engine.computeEmbedding([
        const Content.text(_text),
      ], options: const EmbeddingOptions(outputSize: 256));
      final rawCut = await engine.computeEmbedding([
        const Content.text(_text),
      ], options: const EmbeddingOptions(outputSize: 256, normalize: false));
      final expected = _normalized(full.sublist(0, 256));
      final noSpecial = await engine.computeEmbedding([
        const Content.text(_text),
      ], options: const EmbeddingOptions(insertSpecialTokens: false));
      print(
        '[eg2 270m $tag] dim=$dim |full|=${_norm(full).toStringAsFixed(6)} '
        '|raw|=${_norm(raw).toStringAsFixed(4)} '
        'max|normalized(raw) - full|=${_maxAbsDiff(_normalized(raw), full).toStringAsExponential(2)} '
        'outputSize 256: len=${cut.length} |cut|=${_norm(cut).toStringAsFixed(6)} '
        'max|cut - normalized(full[0:256])|=${_maxAbsDiff(cut, expected).toStringAsExponential(2)} '
        'max|rawCut - raw[0:256]|=${_maxAbsDiff(rawCut, raw.sublist(0, 256)).toStringAsExponential(2)} '
        'cos(no special tokens, full)=${_cos(noSpecial, full).toStringAsFixed(4)}',
      );
      expect(full.length, dim);
      expect(_norm(full), closeTo(1, 1e-4));
      expect(_norm(raw), isNot(closeTo(1, 1e-2)));
      expect(_maxAbsDiff(_normalized(raw), full), lessThan(1e-5));
      expect(cut.length, 256);
      expect(_norm(cut), closeTo(1, 1e-4));
      expect(_maxAbsDiff(cut, expected), lessThan(1e-5));
      expect(rawCut.length, 256);
      expect(_maxAbsDiff(rawCut, raw.sublist(0, 256)), lessThan(1e-5));
      expect(_cos(noSpecial, full), lessThan(0.999));
      await expectLater(
        engine.computeEmbedding([
          const Content.text(_text),
        ], options: EmbeddingOptions(outputSize: dim + 1)),
        throwsArgumentError,
      );
    });

    test('maxInputLength picks the signature that is the limit', () async {
      for (final (asked, limit) in [(256, 256), (300, 512), (2048, 2048)]) {
        final engine = await open(model270m!, maxInputLength: asked);
        // `the` is one token: 2 + n tokens with BOS and EOS.
        final fits = List.filled(limit - 2, 'the').join(' ');
        final over = List.filled(limit - 1, 'the').join(' ');
        final ok = await engine.computeEmbedding([Content.text(fits)]);
        Object? error;
        try {
          await engine.computeEmbedding([Content.text(over)]);
        } on EmbedderInputTooLongException catch (e) {
          error = e;
        }
        final tooLong = error as EmbedderInputTooLongException?;
        print(
          '[eg2 270m $tag] maxInputLength $asked: maxInputTokens='
          '${engine.info.maxInputTokens}, ${limit - 2}+2 tokens -> '
          '${ok.length} values, ${limit - 1}+2 -> '
          '${tooLong == null ? 'embedded' : 'refused (max ${tooLong.maxInputTokens}, actual ${tooLong.actualTokens})'}',
        );
        expect(engine.info.maxInputTokens, limit);
        expect(tooLong?.maxInputTokens, limit);
        expect(tooLong?.actualTokens, limit + 1);
        await engine.close();
      }
      await expectLater(
        open(model270m!, maxInputLength: 9000),
        throwsA(isA<EmbedderLoadException>()),
      );
    });

    test('activationDataType float32 and float16', () async {
      final base = await (await open(
        model270m!,
      )).computeEmbedding([const Content.text(_text)]);
      for (final type in ActivationDataType.values) {
        final engine = await open(model270m, activationDataType: type);
        final v = await engine.computeEmbedding([const Content.text(_text)]);
        print(
          '[eg2 270m $tag] activationDataType ${type.name}: cos to the '
          "bundle's own = ${_cos(v, base).toStringAsFixed(6)}",
        );
        expect(v.length, base.length);
        expect(v.every((x) => x.isFinite), isTrue);
        await engine.close();
      }
    });
  });

  group(
    '440m images ($tag)',
    skip: model440m == null || image == null
        ? 'EG2_440M_LITERTLM and EG2_IMAGE'
        : null,
    () {
      test('a request at 70 vision tokens on an engine at 140', () async {
        final bytes = Uint8List.fromList(File(image!).readAsBytesSync());
        final engine140 = await open(
          model440m!,
          visionBackend: const Backend.cpu(),
        );
        final at140 = await engine140.computeEmbedding([
          Content.imageBytes(bytes),
        ]);
        final at70 = await engine140.computeEmbedding([
          Content.imageBytes(bytes),
        ], options: const EmbeddingOptions(visionTokensPerImage: 70));
        await engine140.close();
        final engine70 = await open(
          model440m,
          visionBackend: const Backend.cpu(),
          visionTokensPerImage: 70,
        );
        final own70 = await engine70.computeEmbedding([
          Content.imageBytes(bytes),
        ]);
        print(
          '[eg2 440m $tag] image: cos(140, request 70)='
          '${_cos(at140, at70).toStringAsFixed(4)}, '
          'max|request 70 on 140 - engine at 70|='
          '${_maxAbsDiff(at70, own70).toStringAsExponential(2)}',
        );
        expect(_maxAbsDiff(at70, own70), lessThan(1e-3));
        await expectLater(
          engine70.computeEmbedding([
            Content.imageBytes(bytes),
          ], options: const EmbeddingOptions(visionTokensPerImage: 140)),
          throwsArgumentError,
        );
      });
    },
  );
}

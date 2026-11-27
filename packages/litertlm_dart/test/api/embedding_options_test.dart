// The EmbeddingEngine's per-request EmbeddingOptions (Kotlin's and Swift's)
// and the config's maxInputLength and activationDataType, over FAKE
// LiteRT-LM bindings: what reaches the native options and settings, the
// vector size an outputSize asks for, the refusals, and that a request's own
// options are deleted with it.
//
// The fake extends the generated bindings with a lookup that throws, so a call
// it does not model fails the test instead of reaching a native library.
@TestOn('vm')
library;

// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:litertlm_dart/internal_io.dart';
import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:litertlm_dart/src/ffi/litert_lm_embedding_bindings.dart';
import 'package:test/test.dart';

import '../litertlm_container_fixture.dart';

const _signatures = [128, 256, 512, 1024, 2048, 8192];
const _text = Content.text('task: search result | query: probe');

void main() {
  late Directory root;
  late String modelPath;
  late _Fake native;

  setUp(() {
    root = Directory.systemTemp.createTempSync('eg2_options_');
    modelPath = '${root.path}/eg2.litertlm';
    File(modelPath).writeAsBytesSync(List.filled(37, 7));
    native = _Fake();
  });
  tearDown(() {
    native.dispose();
    root.deleteSync(recursive: true);
  });

  Future<EmbeddingEngine> open({
    int? maxInputLength,
    int? activationDataType,
    bool images = false,
    int visionTokensPerImage = 140,
  }) async {
    final engine = await createEmbeddingEngineWith(
      LiteRtLmEmbeddingConfig(
        modelPath: modelPath,
        cacheBase: '${root.path}/cache',
        declaredMedia: {if (images) EmbedderModality.image},
        visionTokensPerImage: visionTokensPerImage,
        maxInputLength: maxInputLength,
        activationDataType: activationDataType,
      ),
      openBindings: () => native,
    );
    addTearDown(engine.close);
    return engine;
  }

  group('per-request EmbeddingOptions', () {
    test('no options: the options made at load, normalised, special tokens '
        'on, no output size', () async {
      final engine = await open();
      final v = await engine.computeEmbedding([_text]);
      expect(v.length, 8);
      final sent = native.lastComputeOptions!;
      expect(sent.normalize, isTrue);
      expect(sent.insertSpecialTokens, isTrue);
      expect(sent.outputSize, isNull);
      expect(sent.visionTokensPerImage, isNull);
      expect(native.created('options'), 1, reason: 'no per-request options');
    });

    test('outputSize, normalize and insertSpecialTokens reach the request '
        'options, which are deleted with the request', () async {
      final engine = await open();
      final v = await engine.computeEmbedding(
        [_text],
        options: const EmbeddingOptions(
          outputSize: 3,
          normalize: false,
          insertSpecialTokens: false,
        ),
      );
      expect(v.length, 3, reason: 'the vector the engine truncated to');
      final sent = native.lastComputeOptions!;
      expect(sent.outputSize, 3);
      expect(sent.normalize, isFalse);
      expect(sent.insertSpecialTokens, isFalse);
      expect(
        sent.overflow,
        LiteRtLmInputOverflowStrategy.kLiteRtLmInputOverflowStrategyTruncate,
        reason: 'overflow stays exact under any options',
      );
      expect(native.created('options'), 2);
      expect(native.live['options'], hasLength(1), reason: 'only load\'s');
    });

    test('an outputSize outside 1..dimension is refused before any native '
        'call', () async {
      final engine = await open();
      for (final size in [0, 9]) {
        await expectLater(
          engine.computeEmbedding([
            _text,
          ], options: EmbeddingOptions(outputSize: size)),
          throwsArgumentError,
        );
      }
      expect(native.computes, 0);
    });

    test('visionTokensPerImage: 70 on an engine at 140 is sent; 140 on one '
        'at 70, an unknown budget or one without images is refused', () async {
      native.visionSignatures = [70, 140];
      final engine140 = await open(images: true);
      await engine140.computeEmbedding([
        Content.imageBytes(Uint8List.fromList([1, 2, 3])),
      ], options: const EmbeddingOptions(visionTokensPerImage: 70));
      expect(native.lastComputeOptions!.visionTokensPerImage, 70);
      await engine140.computeEmbedding([
        Content.imageBytes(Uint8List.fromList([1, 2, 3])),
      ], options: const EmbeddingOptions(visionTokensPerImage: 140));
      expect(native.lastComputeOptions!.visionTokensPerImage, 140);
      await expectLater(
        engine140.computeEmbedding([
          _text,
        ], options: const EmbeddingOptions(visionTokensPerImage: 100)),
        throwsArgumentError,
      );
      await engine140.close();

      final engine70 = await open(images: true, visionTokensPerImage: 70);
      await expectLater(
        engine70.computeEmbedding([
          _text,
        ], options: const EmbeddingOptions(visionTokensPerImage: 140)),
        throwsArgumentError,
      );
      await engine70.close();

      final textOnly = await open();
      await expectLater(
        textOnly.computeEmbedding([
          _text,
        ], options: const EmbeddingOptions(visionTokensPerImage: 70)),
        throwsArgumentError,
      );
    });
  });

  group('EmbeddingEngineConfig', () {
    test('maxInputLength is set, and its signature is the limit', () async {
      final engine = await open(maxInputLength: 300);
      expect(native.maxInputLength, 300);
      expect(engine.info.maxInputTokens, 512);
    });

    test('no maxInputLength: 1024', () async {
      final engine = await open();
      expect(native.maxInputLength, 1024);
      expect(engine.info.maxInputTokens, 1024);
    });

    test('a maxInputLength above the largest signature is refused before '
        'any engine', () async {
      await expectLater(
        open(maxInputLength: 8193),
        throwsA(
          isA<EmbedderLoadException>().having(
            (e) => e.message,
            'message',
            contains('8192'),
          ),
        ),
      );
      expect(native.created('engine'), 0);
    });

    test('activationDataType reaches the settings, and none is set when it '
        'is null', () async {
      await open(activationDataType: 0);
      expect(
        native.activation,
        LiteRtLmActivationDataType.kLiteRtLmActivationDataTypeFloat32,
      );
      await open(activationDataType: 1);
      expect(
        native.activation,
        LiteRtLmActivationDataType.kLiteRtLmActivationDataTypeFloat16,
      );
      native.activation = null;
      await open();
      expect(native.activation, isNull);
    });

    test('the public config hands both to the embedder', () async {
      final bundle = File('${root.path}/g.litertlm')
        ..writeAsBytesSync(eg2Container());
      final placed = await embedderConfigFor(
        EmbeddingEngineConfig(
          modelPath: bundle.path,
          cacheDir: root.path,
          maxInputLength: 256,
          activationDataType: ActivationDataType.float16,
        ),
      );
      expect(placed.maxInputLength, 256);
      expect(placed.activationDataType, 1);
      expect(
        () => EmbeddingEngineConfig(modelPath: modelPath, maxInputLength: 0),
        throwsArgumentError,
      );
    });
  });
}

/// What one native options object holds.
final class _Options {
  bool normalize = true;
  bool insertSpecialTokens = true;
  LiteRtLmInputOverflowStrategy? overflow;
  int? outputSize;
  int? visionTokensPerImage;
}

Pointer<T> _noLookup<T extends NativeType>(String symbol) =>
    throw UnimplementedError('the fake does not model $symbol');

final class _Fake extends LiteRtLmEmbeddingBindings {
  _Fake() : super.fromLookup(_noLookup);

  static const dimension = 8;
  List<int>? visionSignatures;

  int? maxInputLength;
  LiteRtLmActivationDataType? activation;
  _Options? lastComputeOptions;
  int computes = 0;

  final live = <String, Set<int>>{};
  final _created = <String, int>{};
  final _options = <int, _Options>{};
  final _responses = <int, ({Pointer<Float> values, int size})>{};
  int _next = 0x10000;
  final _error = 'fake error'.toNativeUtf8();

  int created(String kind) => _created[kind] ?? 0;

  void dispose() {
    for (final r in _responses.values) {
      calloc.free(r.values);
    }
    calloc.free(_error);
  }

  Pointer<T> _make<T extends NativeType>(String kind) {
    final address = _next += 0x10;
    (live[kind] ??= {}).add(address);
    _created[kind] = created(kind) + 1;
    return Pointer.fromAddress(address);
  }

  void _drop(String kind, Pointer<NativeType> p) {
    if (!(live[kind]?.remove(p.address) ?? false)) {
      throw StateError('$kind ${p.address} deleted twice or never made');
    }
    if (live[kind]!.isEmpty) live.remove(kind);
  }

  int _out<T extends NativeType>(Pointer<Pointer<T>> out, String kind) {
    out.value = _make<T>(kind);
    return 0;
  }

  int _list(List<int>? v, Pointer<Int32> lengths, int max, Pointer<Size> n) {
    if (v == null) return 5; // NOT_FOUND
    if (lengths != nullptr) {
      for (var i = 0; i < v.length && i < max; i++) {
        lengths[i] = v[i];
      }
    }
    n.value = v.length;
    return 0;
  }

  @override
  void litert_lm_clear_last_error() {}

  @override
  Pointer<Char> litert_lm_get_last_error_message() => _error.cast();

  @override
  int litert_lm_loaded_file_create(
    Pointer<Char> path,
    Pointer<Pointer<LiteRtLmLoadedFile>> out,
  ) => _out(out, 'loaded_file');

  @override
  void litert_lm_loaded_file_delete(Pointer<LiteRtLmLoadedFile> f) =>
      _drop('loaded_file', f);

  @override
  int litert_lm_loaded_file_model_type(
    Pointer<LiteRtLmLoadedFile> f,
    Pointer<UnsignedInt> out,
  ) {
    out.value = LiteRtLmModelType.kLiteRtLmModelTypeEmbedding.value;
    return 0;
  }

  @override
  int litert_lm_loaded_file_embedding_dimension(
    Pointer<LiteRtLmLoadedFile> f,
    Pointer<Int32> out,
  ) {
    out.value = dimension;
    return 0;
  }

  @override
  int litert_lm_loaded_file_embedding_signature_selection(
    Pointer<LiteRtLmLoadedFile> f,
    Pointer<Int32> lengths,
    int max,
    Pointer<Size> n,
  ) => _list(_signatures, lengths, max, n);

  @override
  int litert_lm_loaded_file_vision_signature_selection(
    Pointer<LiteRtLmLoadedFile> f,
    Pointer<Int32> lengths,
    int max,
    Pointer<Size> n,
  ) => _list(visionSignatures, lengths, max, n);

  @override
  int litert_lm_embedding_engine_settings_create(
    Pointer<Char> model,
    Pointer<Char> backend,
    Pointer<Char> vision,
    Pointer<Char> audio,
    Pointer<Pointer<LiteRtLmEmbeddingEngineSettings>> out,
  ) => _out(out, 'settings');

  @override
  void litert_lm_embedding_engine_settings_delete(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
  ) => _drop('settings', s);

  @override
  int litert_lm_embedding_engine_settings_set_cache_dir(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
    Pointer<Char> dir,
  ) => 0;

  @override
  int litert_lm_embedding_engine_settings_set_max_input_length(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
    int length,
  ) {
    maxInputLength = length;
    return 0;
  }

  @override
  int litert_lm_embedding_engine_settings_set_vision_tokens_per_image(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
    int budget,
  ) => 0;

  @override
  int litert_lm_embedding_engine_settings_set_activation_data_type(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
    LiteRtLmActivationDataType type,
  ) {
    activation = type;
    return 0;
  }

  @override
  int litert_lm_embedding_engine_create(
    Pointer<LiteRtLmEmbeddingEngineSettings> s,
    Pointer<Pointer<LiteRtLmEmbeddingEngine>> out,
  ) => _out(out, 'engine');

  @override
  void litert_lm_embedding_engine_delete(Pointer<LiteRtLmEmbeddingEngine> e) =>
      _drop('engine', e);

  @override
  int litert_lm_embedding_options_create(
    Pointer<Pointer<LiteRtLmEmbeddingOptions>> out,
  ) {
    _out(out, 'options');
    _options[out.value.address] = _Options();
    return 0;
  }

  @override
  void litert_lm_embedding_options_delete(Pointer<LiteRtLmEmbeddingOptions> o) {
    _drop('options', o);
    _options.remove(o.address);
  }

  @override
  int litert_lm_embedding_options_set_normalize(
    Pointer<LiteRtLmEmbeddingOptions> o,
    bool normalize,
  ) {
    _options[o.address]!.normalize = normalize;
    return 0;
  }

  @override
  int litert_lm_embedding_options_set_insert_special_tokens(
    Pointer<LiteRtLmEmbeddingOptions> o,
    bool insert,
  ) {
    _options[o.address]!.insertSpecialTokens = insert;
    return 0;
  }

  @override
  int litert_lm_embedding_options_set_input_overflow_strategy(
    Pointer<LiteRtLmEmbeddingOptions> o,
    LiteRtLmInputOverflowStrategy strategy,
  ) {
    _options[o.address]!.overflow = strategy;
    return 0;
  }

  @override
  int litert_lm_embedding_options_set_output_size(
    Pointer<LiteRtLmEmbeddingOptions> o,
    int size,
  ) {
    _options[o.address]!.outputSize = size;
    return 0;
  }

  @override
  int litert_lm_embedding_options_set_vision_tokens_per_image(
    Pointer<LiteRtLmEmbeddingOptions> o,
    int budget,
  ) {
    _options[o.address]!.visionTokensPerImage = budget;
    return 0;
  }

  @override
  int litert_lm_input_data_create(
    LiteRtLmInputDataType type,
    Pointer<Void> data,
    int size,
    Pointer<Pointer<LiteRtLmInputData>> out,
  ) => _out(out, 'input');

  @override
  void litert_lm_input_data_delete(Pointer<LiteRtLmInputData> d) =>
      _drop('input', d);

  @override
  int litert_lm_embedding_engine_compute_embedding(
    Pointer<LiteRtLmEmbeddingEngine> engine,
    Pointer<Pointer<LiteRtLmInputData>> inputs,
    int count,
    Pointer<LiteRtLmEmbeddingOptions> options,
    Pointer<Pointer<LiteRtLmEmbeddingResponse>> out,
  ) {
    computes++;
    final sent =
        _options[options.address] ??
        (throw StateError('compute with dead options'));
    lastComputeOptions = sent;
    // As LiteRT-LM: the first outputSize values (normalisation not modelled).
    final size = sent.outputSize ?? dimension;
    final values = calloc<Float>(size);
    for (var i = 0; i < size; i++) {
      values[i] = (i + 1) / 10;
    }
    final response = _make<LiteRtLmEmbeddingResponse>('response');
    _responses[response.address] = (values: values, size: size);
    out.value = response;
    return 0;
  }

  @override
  int litert_lm_embedding_response_get_size(
    Pointer<LiteRtLmEmbeddingResponse> r,
    Pointer<Size> out,
  ) {
    out.value = _responses[r.address]!.size;
    return 0;
  }

  @override
  int litert_lm_embedding_response_get_values(
    Pointer<LiteRtLmEmbeddingResponse> r,
    Pointer<Pointer<Float>> out,
  ) {
    out.value = _responses[r.address]!.values;
    return 0;
  }

  @override
  int litert_lm_embedding_response_get_input_length(
    Pointer<LiteRtLmEmbeddingResponse> r,
    Pointer<Int> out,
  ) {
    out.value = 12;
    return 0;
  }

  @override
  int litert_lm_embedding_response_get_truncated_length(
    Pointer<LiteRtLmEmbeddingResponse> r,
    Pointer<Int> out,
  ) {
    out.value = 0;
    return 0;
  }

  @override
  void litert_lm_embedding_response_delete(
    Pointer<LiteRtLmEmbeddingResponse> r,
  ) {
    _drop('response', r);
    calloc.free(_responses.remove(r.address)!.values);
  }
}

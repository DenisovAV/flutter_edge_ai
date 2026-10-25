// `LiteRtLmWebEmbeddingPass` (web, EmbeddingGemma 2 over @litert-lm/core's
// EmbeddingEngine) on the VM, over a fake runtime that models what the real
// one does with the settings and options it is given. The real interop is the
// browser's (example/integration_test/web_eg2_test.dart on the GCE VM); here:
// the named error for a page without the shim line, the WebGPU refusal before
// anything is created (no navigator.gpu, no adapter, a failed request) and the
// reason a CPU create fails, the settings that reach `EmbeddingEngine.create`
// (GPU, maxInputLength 1024, the vision tower only when images are declared,
// the budget), the load probe (dimension, NaN/zero refused, and the limit the
// engine enforces: where it cuts, and — WebGPU, which ignores the overflow
// strategy and averages windows — its window, pinned at 1024/1025 tokens and
// never guessed), what reaches `computeEmbedding` (`taskType.prefix + text`
// for all nine task types, image bytes untouched, normalize + special tokens +
// TRUNCATE), the typed overflow with the engine's exact counts for a cut or a
// split input, `opfs://` resolve and revoke, close, and one case through
// core's inline host. Audio and combined inputs (1.13.2): the container
// header read through the runtime before any engine exists — the 270m and the
// 440m refused by name, the 740m's audio tower on WebGPU — the audio bytes
// untouched, the parts of a combined input in the native order as one
// request, its overflow with exact counts, and core's D17 gate letting a
// combined input through.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_edge_ai/engine.dart';
// ignore: implementation_imports — the app-facing model over core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
// ignore: implementation_imports — the app-facing model over core's inline host, which is internal to core
import 'package:flutter_edge_ai/src/embedding/embedding_host_web.dart'
    as inline;
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_common.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/web/litert_lm_web_embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

/// "Tokens" as the fake engine counts them: one per character of a text part
/// (prefix included), plus BOS and EOS when special tokens are on — except the
/// pass's probes, runs of `the`, which count one per word as the real
/// tokenizer reads them; an image is [_imageTokens], an audio clip one per
/// byte (a test picks its length).
const _imageTokens = 140;

int _partTokens(LiteRtLmWebInput input) => switch (input) {
  LiteRtLmWebText(:final text) => _textTokens(text),
  LiteRtLmWebImage() => _imageTokens,
  LiteRtLmWebAudio(:final bytes) => bytes.length,
  LiteRtLmWebParts(:final parts) => parts.fold(
    0,
    (sum, part) => sum + _partTokens(part),
  ),
};

/// The container headers of the three EmbeddingGemma 2 bundles, cut at their
/// header end (test/ffi/fixtures/README.md): what `readPrefix` serves.
Uint8List _header(String bundle) => File(
  'test/ffi/fixtures/embeddinggemma2_${bundle}_header.litertlm',
).readAsBytesSync();

int _textTokens(String text) => RegExp(r'^the( the)*$').hasMatch(text)
    ? text.split(' ').length
    : text.length;

/// The unit vector the fake returns when asked to normalise, and the raw one
/// otherwise — so a pass that stops asking for normalisation is visible.
const _unit = [0.5, 0.5, 0.5, 0.5];
const _raw = [1.0, 1.0, 1.0, 1.0];

final class _FakeEngine implements LiteRtLmWebEngine {
  _FakeEngine(this.settings, this.runtime);

  final LiteRtLmWebEngineSettings settings;
  final _FakeRuntime runtime;

  final calls = <(LiteRtLmWebInput, LiteRtLmWebEmbeddingOptions)>[];
  int deletes = 0;

  @override
  Future<LiteRtLmWebEmbedding> computeEmbedding(
    LiteRtLmWebInput input,
    LiteRtLmWebEmbeddingOptions options,
  ) async {
    if (deletes > 0) throw StateError('engine deleted');
    calls.add((input, options));
    if (runtime.computeError case final error?) throw error;
    final special = options.insertSpecialTokens ? 2 : 0;
    final tokens = _partTokens(input) + special;
    // The largest signature the engine prepared.
    final limit = runtime.maxSignature;
    var vector = options.normalize ? _unit : _raw;
    if (runtime.vectorFor case final override?) vector = override(input);
    if (tokens <= limit || runtime.neverTruncates) {
      return (
        embedding: vector,
        inputLength: tokens,
        truncatedLength: null,
        numChunks: 1,
      );
    }
    if (runtime.webGpu) {
      // @litert-lm/core 0.18.0 on WebGPU: whatever the strategy, windows of
      // the signature, averaged (measured on Chrome 155).
      return (
        embedding: vector,
        inputLength: tokens,
        truncatedLength: null,
        numChunks: (tokens + limit - 1) ~/ limit,
      );
    }
    return switch (options.inputOverflowStrategy) {
      LiteRtLmWebOverflowStrategy.truncate => (
        embedding: vector,
        inputLength: tokens,
        truncatedLength: limit,
        numChunks: 1,
      ),
      LiteRtLmWebOverflowStrategy.chunkAndAverage => (
        embedding: vector,
        inputLength: tokens,
        truncatedLength: null,
        numChunks: (tokens + limit - 1) ~/ limit,
      ),
      LiteRtLmWebOverflowStrategy.error => throw StateError(
        'INVALID_ARGUMENT: Input sequence length ($tokens) exceeds maximum '
        'supported signature length ($limit).',
      ),
    };
  }

  @override
  Future<void> delete() async => deletes++;
}

final class _FakeRuntime implements LiteRtLmWebRuntime {
  LiteRtLmWebRuntimeState state = LiteRtLmWebRuntimeState.ready;
  LiteRtLmWebGpuSupport gpu = LiteRtLmWebGpuSupport.available;
  Object? gpuError;
  Object? readyError;
  Object? createError;
  Object? computeError;

  /// The text signature the engine keeps for `maxInputLength` 1024.
  int maxSignature = 1024;

  /// A model whose limit is beyond the probe: nothing is ever truncated.
  bool neverTruncates = false;

  /// The engine's WebGPU behaviour: the overflow strategy is ignored, and an
  /// over-long input is split into windows of [maxSignature] and averaged.
  bool webGpu = false;

  List<double> Function(LiteRtLmWebInput input)? vectorFor;

  /// The installed file `readPrefix` serves the start of: the 740m's header
  /// by default (it has an audio encoder).
  Uint8List file = _header('740m');
  Object? readError;

  /// Every `readPrefix` call: the URL and the length asked for.
  final reads = <(String, int)>[];

  int readyChecks = 0;
  int gpuChecks = 0;

  /// The runtime calls, in order: `ready`, `gpu`, `read`, `create`.
  final calls = <String>[];
  final created = <_FakeEngine>[];

  _FakeEngine get engine => created.single;

  @override
  Future<LiteRtLmWebRuntimeState> ensureReady() async {
    readyChecks++;
    calls.add('ready');
    if (readyError case final error?) throw error;
    return state;
  }

  @override
  Future<LiteRtLmWebGpuSupport> webGpuSupport() async {
    gpuChecks++;
    calls.add('gpu');
    if (gpuError case final error?) throw error;
    return gpu;
  }

  @override
  Future<LiteRtLmWebEngine> create(LiteRtLmWebEngineSettings settings) async {
    calls.add('create');
    if (createError case final error?) throw error;
    final engine = _FakeEngine(settings, this);
    created.add(engine);
    return engine;
  }

  @override
  Future<Uint8List> readPrefix(String url, int length) async {
    calls.add('read');
    reads.add((url, length));
    if (readError case final error?) throw error;
    return Uint8List.sublistView(file, 0, length.clamp(0, file.length));
  }
}

LiteRtLmWebEmbeddingConfig _config(
  _FakeRuntime runtime, {
  String modelPath = 'blob:eg2',
  Set<EmbeddingModality> media = const {},
  int visionTokensPerImage = 140,
  List<String>? resolved,
  List<String>? revoked,
  LiteRtLmWebBackend? backend,
  String fileName = 'embeddinggemma-2-text-vision-440m.litertlm',
}) => LiteRtLmWebEmbeddingConfig(
  modelPath: modelPath,
  fileName: fileName,
  runtime: runtime,
  resolveUrl: (path) async {
    resolved?.add(path);
    return path.startsWith('opfs://')
        ? 'blob:resolved/${path.substring('opfs://'.length)}'
        : path;
  },
  revokeUrl: (url) => revoked?.add(url),
  declaredMedia: media,
  visionTokensPerImage: visionTokensPerImage,
  backend: backend ?? LiteRtLmWebBackend.gpu,
);

LiteRtLmWebEmbeddingPass _pass(
  _FakeRuntime runtime, {
  Set<EmbeddingModality> media = const {},
  int visionTokensPerImage = 140,
}) => LiteRtLmWebEmbeddingPass(
  _config(runtime, media: media, visionTokensPerImage: visionTokensPerImage),
);

/// A PNG header, enough for core's sniffer.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, //
]);

/// A WAV clip of [tokens] fake tokens (the fake counts one per byte).
Uint8List _wav([int tokens = 100]) => Uint8List.fromList([
  ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WAVEfmt '.codeUnits, //
  ...List.filled(tokens - 16, 7),
]);

/// An M4A header (`ftyp` at 4), which the engine cannot decode.
final _m4a = Uint8List.fromList([
  0, 0, 0, 0x20, ...'ftypM4A '.codeUnits, 0, 0, 0, 0, //
]);

/// A WebP header (RIFF....WEBP), which the engine cannot decode.
final _webp = Uint8List.fromList([
  ...'RIFF'.codeUnits, 0, 0, 0, 0, ...'WEBPVP8 '.codeUnits, 1, 2, 3, //
]);

TypeMatcher<EmbeddingLoadException> _loadError(Object message) =>
    isA<EmbeddingLoadException>()
        .having((e) => e.engine, 'engine', liteRtLmEngineTag)
        .having((e) => e.message, 'message', message);

void main() {
  group('load', () {
    test('a text-only load: WebGPU checked before create, GPU, '
        'maxInputLength 1024, no vision tower, the dimension and limit read '
        'from the probe', () async {
      final runtime = _FakeRuntime();
      final pass = LiteRtLmWebEmbeddingPass(
        // The default backend, as describe() builds it.
        LiteRtLmWebEmbeddingConfig(
          modelPath: 'blob:eg2',
          fileName: 'embeddinggemma-2-text-270m.litertlm',
          runtime: runtime,
          resolveUrl: (path) async => path,
          revokeUrl: (_) {},
        ),
      );

      final info = await pass.load();

      expect(runtime.calls, ['ready', 'gpu', 'create']);
      final settings = runtime.engine.settings;
      expect(settings.modelUrl, 'blob:eg2');
      expect(settings.backend, LiteRtLmWebBackend.gpu);
      expect(settings.maxInputLength, 1024);
      expect(settings.minInputLength, isNull, reason: 'the runtime default');
      expect(settings.visionBackend, isNull, reason: 'unset = no vision tower');
      expect(settings.visionTokensPerImage, isNull);
      expect(info.visionTokensPerImage, isNull);
      expect(info.dimension, 4);
      expect(info.maxInputTokens, 1024);
      expect(info.modalities, {EmbeddingModality.text});
      expect(info.imageFormats, isEmpty);
      await pass.close();
    });

    test('the probe is longer than any EmbeddingGemma 2 signature (8192) and '
        'runs under TRUNCATE, so the limit it reports is the one the engine '
        'enforces', () async {
      final runtime = _FakeRuntime()..maxSignature = 2048;
      final pass = _pass(runtime);

      final info = await pass.load();

      final (probe, options) = runtime.engine.calls.single;
      final words = (probe as LiteRtLmWebText).text.split(' ');
      expect(words.length, greaterThan(8192));
      expect(
        options.inputOverflowStrategy,
        LiteRtLmWebOverflowStrategy.truncate,
      );
      expect(info.maxInputTokens, 2048, reason: 'what the engine cut it at');
      await pass.close();
    });

    test('a model the probe does not overflow reports no limit', () async {
      final runtime = _FakeRuntime()..neverTruncates = true;
      final pass = _pass(runtime);
      expect((await pass.load()).maxInputTokens, isNull);
      await pass.close();
    });

    for (final budget in [140, 70]) {
      test('images declared: the vision tower on the same backend, '
          '$budget tokens per image, {text, image} and the four '
          'containers', () async {
        final runtime = _FakeRuntime();
        final pass = _pass(
          runtime,
          media: {EmbeddingModality.image},
          visionTokensPerImage: budget,
        );

        final info = await pass.load();

        final settings = runtime.engine.settings;
        expect(settings.visionBackend, LiteRtLmWebBackend.gpu);
        expect(settings.visionTokensPerImage, budget);
        expect(info.visionTokensPerImage, budget, reason: 'reported to core');
        expect(info.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
        });
        expect(info.imageFormats, {
          EncodedMediaFormat.jpeg,
          EncodedMediaFormat.png,
          EncodedMediaFormat.gif,
          EncodedMediaFormat.bmp,
        });
        expect(info.imageFormats, liteRtLmImageFormats);
        await pass.close();
      });
    }

    test('a page without @litert-lm/core: the named error, nothing resolved '
        'or created', () async {
      final runtime = _FakeRuntime()
        ..state = LiteRtLmWebRuntimeState.loaderMissing;
      final resolved = <String>[];
      final pass = LiteRtLmWebEmbeddingPass(
        _config(runtime, resolved: resolved),
      );
      await expectLater(
        pass.load(),
        throwsA(
          _loadError(
            allOf(
              contains('web/index.html does not load @litert-lm/core'),
              contains('window.EmbeddingEngine = m.EmbeddingEngine;'),
            ),
          ),
        ),
      );
      expect(resolved, isEmpty);
      expect(runtime.created, isEmpty);
      await pass.close();
    });

    test('a page set up for the LLM engine only (no window.EmbeddingEngine): '
        'the error names the missing line', () async {
      final runtime = _FakeRuntime()
        ..state = LiteRtLmWebRuntimeState.embeddingEngineMissing;
      final pass = _pass(runtime);
      await expectLater(
        pass.load(),
        throwsA(
          _loadError(
            allOf(
              startsWith('window.EmbeddingEngine is not set'),
              contains(
                'Add window.EmbeddingEngine = m.EmbeddingEngine; next to '
                'window.Engine = m.Engine;',
              ),
            ),
          ),
        ),
      );
      expect(runtime.created, isEmpty);
      await pass.close();
    });

    test('a loader that failed (the CDN import rejected) is a load error '
        'carrying the cause', () async {
      final failure = StateError('Failed to fetch dynamically imported module');
      final runtime = _FakeRuntime()..readyError = failure;
      await expectLater(
        _pass(runtime).load(),
        throwsA(
          _loadError(
            contains('@litert-lm/core did not load on this page'),
          ).having((e) => e.cause, 'cause', failure),
        ),
      );
    });

    for (final (support, why) in [
      (LiteRtLmWebGpuSupport.noWebGpu, 'this browser has no WebGPU'),
      (LiteRtLmWebGpuSupport.noAdapter, 'WebGPU found no GPU adapter'),
    ]) {
      test('${support.name}: refused before anything is resolved or created, '
          'saying EmbeddingGemma 2 on the web needs WebGPU and why there is no '
          'CPU fallback', () async {
        final runtime = _FakeRuntime()..gpu = support;
        final resolved = <String>[];
        final pass = LiteRtLmWebEmbeddingPass(
          _config(
            runtime,
            media: {EmbeddingModality.image},
            resolved: resolved,
          ),
        );
        await expectLater(
          pass.load(),
          throwsA(
            _loadError(
              allOf(
                startsWith('EmbeddingGemma 2 on the web needs WebGPU'),
                contains(why),
                contains('embeddinggemma-2-text-vision-440m.litertlm'),
                contains('There is no CPU fallback'),
                contains(
                  'the CPU (WebAssembly) path of @litert-lm/core 0.18.0 '
                  'cannot read the external weights',
                ),
              ),
            ).having((e) => e.cause, 'cause', isNull),
          ),
        );
        expect(runtime.calls, ['ready', 'gpu']);
        expect(resolved, isEmpty);
        expect(runtime.created, isEmpty);
        await pass.close();
      });
    }

    test('the adapter request itself fails: refused before create, with the '
        'cause', () async {
      final failure = StateError('SecurityError: requestAdapter');
      final runtime = _FakeRuntime()..gpuError = failure;
      await expectLater(
        _pass(runtime).load(),
        throwsA(
          _loadError(
            allOf(
              startsWith('EmbeddingGemma 2 on the web needs WebGPU'),
              contains('asking the browser for a WebGPU adapter failed'),
              contains('SecurityError: requestAdapter'),
            ),
          ).having((e) => e.cause, 'cause', failure),
        ),
      );
      expect(runtime.created, isEmpty);
    });

    test('a page without the shim line is named before WebGPU is '
        'asked', () async {
      final runtime = _FakeRuntime()
        ..state = LiteRtLmWebRuntimeState.embeddingEngineMissing
        ..gpu = LiteRtLmWebGpuSupport.noWebGpu;
      await expectLater(
        _pass(runtime).load(),
        throwsA(_loadError(startsWith('window.EmbeddingEngine is not set'))),
      );
      expect(runtime.gpuChecks, 0);
    });

    test('CPU, selected only by the drive suite\'s record: WebGPU is not '
        'asked, and a create failure says why the CPU path cannot load the '
        'EmbeddingGemma 2 bundles', () async {
      final runtime = _FakeRuntime()
        ..gpu = LiteRtLmWebGpuSupport.noWebGpu
        ..createError = StateError(
          'Failed to get external weight for buffer id 2147483863 '
          '(tensor 1451)',
        );
      final pass = LiteRtLmWebEmbeddingPass(
        _config(runtime, backend: LiteRtLmWebBackend.cpu),
      );
      await expectLater(
        pass.load(),
        throwsA(
          _loadError(
            allOf(
              contains('could not create the embedding engine'),
              contains('(cpu)'),
              contains('Failed to get external weight'),
              contains(
                'The CPU (WebAssembly) path of @litert-lm/core 0.18.0 cannot '
                'read the external weights of the EmbeddingGemma 2 .litertlm '
                'bundles; they load on WebGPU',
              ),
            ),
          ),
        ),
      );
      expect(runtime.calls, ['ready', 'create']);
      expect(
        runtime.created,
        isEmpty,
        reason: 'the create itself was attempted and failed',
      );
      await pass.close();

      // With images too, the CPU is the reason: no vision-encoder or LLM
      // hint to send the reader the wrong way.
      final withImages = _FakeRuntime()..createError = StateError('x');
      await expectLater(
        LiteRtLmWebEmbeddingPass(
          _config(
            withImages,
            backend: LiteRtLmWebBackend.cpu,
            media: {EmbeddingModality.image},
          ),
        ).load(),
        throwsA(
          _loadError(
            allOf(
              contains('The CPU (WebAssembly) path'),
              isNot(contains('vision encoder (')),
              isNot(contains('close it first')),
            ),
          ),
        ),
      );
    });

    test('audio declared on the 740m: its container header is read through '
        'the page before the engine exists, then the audio tower on WebGPU; '
        '{text, audio}, WAV/MP3/FLAC, combined inputs', () async {
      final runtime = _FakeRuntime();
      final revoked = <String>[];
      final pass = LiteRtLmWebEmbeddingPass(
        _config(
          runtime,
          modelPath: 'opfs://eg2.litertlm',
          media: {EmbeddingModality.audio},
          revoked: revoked,
          fileName: 'embeddinggemma-2-740m.litertlm',
        ),
      );

      final info = await pass.load();

      expect(runtime.calls, ['ready', 'gpu', 'read', 'read', 'create']);
      expect(runtime.reads, [
        ('blob:resolved/eg2.litertlm', 32),
        ('blob:resolved/eg2.litertlm', 2176),
      ], reason: 'the preamble, then up to the header end; nothing past it');
      final settings = runtime.engine.settings;
      expect(settings.audioBackend, LiteRtLmWebBackend.gpu);
      expect(settings.audioBackend, liteRtLmWebAudioBackend);
      expect(settings.visionBackend, isNull, reason: 'images not declared');
      expect(info.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.audio,
      });
      expect(info.audioFormats, {
        EncodedMediaFormat.wav,
        EncodedMediaFormat.mp3,
        EncodedMediaFormat.flac,
      });
      expect(info.audioFormats, liteRtLmAudioFormats);
      expect(info.imageFormats, isEmpty);
      expect(info.combinedInputs, isTrue);
      expect(revoked, ['blob:resolved/eg2.litertlm']);
      await pass.close();
    });

    test(
      'images and audio declared: both towers, {text, image, audio}',
      () async {
        final runtime = _FakeRuntime();
        final info = await _pass(
          runtime,
          media: {EmbeddingModality.image, EmbeddingModality.audio},
        ).load();
        final settings = runtime.engine.settings;
        expect(settings.visionBackend, LiteRtLmWebBackend.gpu);
        expect(settings.audioBackend, LiteRtLmWebBackend.gpu);
        expect(settings.visionTokensPerImage, 140);
        expect(info.modalities, EmbeddingModality.values.toSet());
      },
    );

    test('no audio declared: no audio tower, and the header is never '
        'read', () async {
      final runtime = _FakeRuntime();
      final info = await _pass(
        runtime,
        media: {EmbeddingModality.image},
      ).load();
      expect(runtime.engine.settings.audioBackend, isNull);
      expect(runtime.reads, isEmpty);
      expect(info.audioFormats, isEmpty);
      expect(info.combinedInputs, isTrue);
    });

    for (final bundle in ['270m', '440m']) {
      test('audio declared on the $bundle: refused from its container header, '
          'naming the 740m, before any engine exists (ModelInfo would claim '
          'audio)', () async {
        final runtime = _FakeRuntime()..file = _header(bundle);
        final revoked = <String>[];
        final pass = LiteRtLmWebEmbeddingPass(
          _config(
            runtime,
            modelPath: 'opfs://eg2.litertlm',
            media: {EmbeddingModality.audio},
            revoked: revoked,
            fileName: 'embeddinggemma-2-$bundle.litertlm',
          ),
        );
        await expectLater(
          pass.load(),
          throwsA(
            _loadError(
              'embeddinggemma-2-$bundle.litertlm has no audio encoder; '
              'install embeddinggemma-2-740m',
            ),
          ),
        );
        expect(runtime.created, isEmpty);
        expect(runtime.calls, isNot(contains('create')));
        expect(revoked, ['blob:resolved/eg2.litertlm']);
        await pass.close();
      });
    }

    for (final (name, mutate, reason) in [
      (
        'not a .litertlm file',
        (_FakeRuntime r) => r.file = Uint8List.fromList(List.filled(64, 0x41)),
        'no LITERTLM magic',
      ),
      (
        'a file that ends inside its header',
        (_FakeRuntime r) => r.file = Uint8List.sublistView(r.file, 0, 1000),
        'ends at 1000, expected 2176',
      ),
      (
        'a read the page cannot do',
        (_FakeRuntime r) =>
            r.readError = StateError('TypeError: Failed to fetch'),
        'TypeError: Failed to fetch',
      ),
    ]) {
      test(
        'audio declared, $name: a load error naming the file and the '
        'reason, with the cause — never "no audio"; nothing created',
        () async {
          final runtime = _FakeRuntime();
          mutate(runtime);
          await expectLater(
            _pass(runtime, media: {EmbeddingModality.audio}).load(),
            throwsA(
              _loadError(
                allOf(
                  startsWith(
                    'could not read the container of '
                    'embeddinggemma-2-text-vision-440m.litertlm to find its '
                    'audio encoder',
                  ),
                  contains(reason),
                ),
              ).having((e) => e.cause, 'cause', isNotNull),
            ),
          );
          expect(runtime.created, isEmpty);
        },
      );
    }

    test('requireLiteRtLmWebAudioEncoderFor (describe()): resolves an opfs:// '
        'path, reads, revokes the URL it made — refused or not', () async {
      for (final (bundle, refused) in [('740m', false), ('270m', true)]) {
        final runtime = _FakeRuntime()..file = _header(bundle);
        final revoked = <String>[];
        final check = requireLiteRtLmWebAudioEncoderFor(
          _config(
            runtime,
            modelPath: 'opfs://eg2.litertlm',
            revoked: revoked,
            fileName: 'eg2.litertlm',
          ),
        );
        if (refused) {
          await expectLater(
            check,
            throwsA(_loadError(contains('has no audio encoder'))),
          );
        } else {
          await check;
        }
        expect(runtime.reads.first.$1, 'blob:resolved/eg2.litertlm');
        expect(revoked, ['blob:resolved/eg2.litertlm']);
        expect(runtime.created, isEmpty);
      }
    });

    test('create fails, text only: the runtime\'s message, no vision '
        'hint', () async {
      final runtime = _FakeRuntime()..createError = StateError('out of memory');
      await expectLater(
        _pass(runtime).load(),
        throwsA(
          _loadError(
            allOf(
              contains('could not create the embedding engine'),
              contains('(gpu)'),
              contains('out of memory'),
              isNot(contains('vision encoder')),
              isNot(contains('CPU (WebAssembly)')),
            ),
          ),
        ),
      );
    });

    test('create fails with images declared (the 270m has no vision '
        'encoder, or an LLM fills the page\'s WebAssembly memory): the '
        'message names the bundle that embeds images and the LLM', () async {
      final runtime = _FakeRuntime()
        ..createError = StateError('NOT_FOUND: vision encoder');
      await expectLater(
        _pass(runtime, media: {EmbeddingModality.image}).load(),
        throwsA(
          _loadError(
            allOf(
              contains('NOT_FOUND: vision encoder'),
              contains('install embeddinggemma-2-text-vision-440m'),
              contains(
                'If a .litertlm LLM is loaded on this page, close it first',
              ),
            ),
          ),
        ),
      );
    });

    test('an opfs:// path reaches the engine as the blob: URL made for it, '
        'which the pass revokes once the engine read it — on success and on '
        'failure; any other path is never revoked', () async {
      for (final fail in [false, true]) {
        final runtime = _FakeRuntime();
        if (fail) runtime.createError = StateError('create failed');
        final revoked = <String>[];
        final pass = LiteRtLmWebEmbeddingPass(
          _config(runtime, modelPath: 'opfs://eg2.litertlm', revoked: revoked),
        );
        if (fail) {
          await expectLater(
            pass.load(),
            throwsA(isA<EmbeddingLoadException>()),
          );
        } else {
          await pass.load();
          expect(
            runtime.engine.settings.modelUrl,
            'blob:resolved/eg2.litertlm',
          );
        }
        expect(revoked, ['blob:resolved/eg2.litertlm']);
        await pass.close();
      }

      final runtime = _FakeRuntime();
      final revoked = <String>[];
      final pass = LiteRtLmWebEmbeddingPass(
        _config(runtime, modelPath: 'blob:core-owned', revoked: revoked),
      );
      await pass.load();
      expect(revoked, isEmpty, reason: 'core owns that URL');
      await pass.close();
    });

    test('an opfs:// path the page cannot open: a load error naming the file '
        'and the path, with the cause; nothing created or revoked', () async {
      final failure = StateError('TypeError: Failed to fetch');
      final runtime = _FakeRuntime();
      final revoked = <String>[];
      final pass = LiteRtLmWebEmbeddingPass(
        LiteRtLmWebEmbeddingConfig(
          modelPath: 'opfs://eg2.litertlm',
          fileName: 'embeddinggemma-2-text-270m.litertlm',
          runtime: runtime,
          resolveUrl: (_) async => throw failure,
          revokeUrl: revoked.add,
        ),
      );
      await expectLater(
        pass.load(),
        throwsA(
          _loadError(
            allOf(
              contains(
                'could not open embeddinggemma-2-text-270m.litertlm from the '
                "page's model storage (opfs://eg2.litertlm)",
              ),
              contains('TypeError: Failed to fetch'),
            ),
          ).having((e) => e.cause, 'cause', failure),
        ),
      );
      expect(runtime.created, isEmpty);
      expect(revoked, isEmpty, reason: 'no URL was made');
      await pass.close();
    });

    for (final (name, vector) in [
      ('NaN', [double.nan, 0.5, 0.5, 0.5]),
      ('infinity', [double.infinity, 0.5, 0.5, 0.5]),
      ('all zeros', [0.0, 0.0, 0.0, 0.0]),
    ]) {
      test('a probe vector with $name (the fp16 failure) refuses the load, '
          'and the close behind it deletes the engine', () async {
        final runtime = _FakeRuntime()..vectorFor = (_) => vector;
        final pass = _pass(runtime);
        await expectLater(
          pass.load(),
          throwsA(_loadError(contains('NaN, infinity or only zeros'))),
        );
        await pass.close();
        expect(runtime.engine.deletes, 1);
      });
    }

    test('a probe that throws refuses the load; the engine is deleted on '
        'close', () async {
      final runtime = _FakeRuntime()..computeError = StateError('wasm trap');
      final pass = _pass(runtime);
      await expectLater(
        pass.load(),
        throwsA(_loadError(contains('wasm trap'))),
      );
      await pass.close();
      expect(runtime.engine.deletes, 1);
    });

    test('load runs once, and never after close', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime);
      await pass.load();
      await expectLater(pass.load(), throwsStateError);
      await pass.close();

      final closed = _pass(_FakeRuntime());
      await closed.close();
      await expectLater(closed.load(), throwsStateError);
    });
  });

  group('WebGPU, where the engine ignores the overflow strategy and averages '
      'windows', () {
    test('the window is pinned at load: 1024 tokens are one window, 1025 '
        'two, so maxInputTokens is 1024', () async {
      final runtime = _FakeRuntime()..webGpu = true;
      final pass = _pass(runtime);

      final info = await pass.load();

      expect(info.maxInputTokens, 1024);
      final texts = [
        for (final (input, _) in runtime.engine.calls)
          (input as LiteRtLmWebText).text.split(' ').length,
      ];
      expect(
        texts,
        [9000, 1022, 1023],
        reason:
            'the probe, then 1024 and '
            '1025 tokens with BOS and EOS',
      );
      await pass.close();
    });

    for (final window in [1000, 2048]) {
      test('a window of $window is not taken for 1024: maxInputTokens is '
          'null', () async {
        final runtime = _FakeRuntime()
          ..webGpu = true
          ..maxSignature = window;
        final pass = _pass(runtime);
        expect((await pass.load()).maxInputTokens, isNull);
        await pass.close();
      });
    }

    test('an over-long text the engine split is '
        'EmbeddingInputTooLongException with the engine\'s exact count; the '
        'averaged vector is never returned, and the pass keeps '
        'working', () async {
      final runtime = _FakeRuntime()..webGpu = true;
      final pass = _pass(runtime);
      await pass.load();
      final prefix = TaskType.retrievalQuery.prefix.length;
      final fits = 'x' * (1024 - prefix - 2);
      expect(
        await pass.embed(EmbeddingInput.text(fits), TaskType.retrievalQuery),
        _unit,
      );
      for (final extra in [1, 2000]) {
        await expectLater(
          pass.embed(
            EmbeddingInput.text('$fits${'y' * extra}'),
            TaskType.retrievalQuery,
          ),
          throwsA(
            isA<EmbeddingInputTooLongException>()
                .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
                .having((e) => e.actualTokens, 'actualTokens', 1024 + extra),
          ),
        );
      }
      expect(await pass.embed(EmbeddingInput.text('ok'), TaskType.none), _unit);
      await pass.close();
    });

    test('split with no pinned window, or a split image: '
        'EmbeddingEngineException, nothing returned', () async {
      final runtime = _FakeRuntime()
        ..webGpu = true
        ..maxSignature = 100;
      final pass = _pass(runtime, media: {EmbeddingModality.image});
      expect((await pass.load()).maxInputTokens, isNull);
      await expectLater(
        pass.embed(EmbeddingInput.text('z' * 300), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.message,
            'message',
            allOf(contains('into 4 windows'), contains('window is unknown')),
          ),
        ),
      );
      await expectLater(
        pass.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.message,
            'message',
            contains('image'),
          ),
        ),
      );
      await pass.close();
    });
  });

  group('embed', () {
    test('text: every task type reaches the engine as prefix + text, with '
        'normalize, special tokens and TRUNCATE', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime);
      await pass.load();
      for (final type in TaskType.values) {
        expect(
          await pass.embed(EmbeddingInput.text('Mount Everest'), type),
          _unit,
        );
      }
      final calls = runtime.engine.calls.skip(1).toList(); // after the probe
      expect(
        [for (final (input, _) in calls) (input as LiteRtLmWebText).text],
        [for (final type in TaskType.values) '${type.prefix}Mount Everest'],
      );
      for (final (_, options) in calls) {
        expect(options.normalize, isTrue);
        expect(options.insertSpecialTokens, isTrue);
        expect(
          options.inputOverflowStrategy,
          LiteRtLmWebOverflowStrategy.truncate,
        );
      }
      await pass.close();
    });

    test('empty text embeds the prefix alone, as on native', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime);
      await pass.load();
      await pass.embed(EmbeddingInput.text(''), TaskType.retrievalQuery);
      expect(
        (runtime.engine.calls.last.$1 as LiteRtLmWebText).text,
        TaskType.retrievalQuery.prefix,
      );
      await pass.close();
    });

    test('at the limit it embeds; one token over is '
        'EmbeddingInputTooLongException with the engine\'s exact counts, the '
        'cut vector is never returned, and the pass keeps working', () async {
      final runtime = _FakeRuntime()..maxSignature = 64;
      final pass = _pass(runtime);
      await pass.load();
      // retrievalQuery's prefix is 30 characters; + BOS and EOS.
      final prefix = TaskType.retrievalQuery.prefix.length;
      final fits = 'x' * (64 - prefix - 2);
      expect(
        await pass.embed(EmbeddingInput.text(fits), TaskType.retrievalQuery),
        _unit,
      );
      await expectLater(
        pass.embed(EmbeddingInput.text('${fits}y'), TaskType.retrievalQuery),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 64)
              .having((e) => e.actualTokens, 'actualTokens', 65),
        ),
      );
      await expectLater(
        pass.embed(EmbeddingInput.text('z' * 3000), TaskType.none),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 64)
              .having((e) => e.actualTokens, 'actualTokens', 3002),
        ),
      );
      expect(await pass.embed(EmbeddingInput.text('ok'), TaskType.none), _unit);
      await pass.close();
    });

    test('an image reaches the engine as its own bytes, without a '
        'prefix', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime, media: {EmbeddingModality.image});
      await pass.load();
      expect(
        await pass.embed(EmbeddingInput.image(_png), TaskType.retrievalQuery),
        _unit,
      );
      final (input, options) = runtime.engine.calls.last;
      expect((input as LiteRtLmWebImage).bytes, _png);
      expect(options.normalize, isTrue);
      await pass.close();
    });

    test('an image or audio on a pass not loaded for it never reaches the '
        'engine (a host bug)', () async {
      final runtime = _FakeRuntime();
      final textOnly = _pass(runtime);
      await textOnly.load();
      for (final input in [
        EmbeddingInput.image(_png),
        EmbeddingInput.audio(_wav()),
      ]) {
        await expectLater(
          textOnly.embed(input, TaskType.none),
          throwsA(isA<EmbeddingEngineException>()),
        );
      }
      expect(runtime.engine.calls, hasLength(1), reason: 'the probe only');
      await textOnly.close();

      // A combined input carrying a medium the pass was not loaded with is
      // refused whole, never sent without it.
      final withImages = _FakeRuntime();
      final images = _pass(withImages, media: {EmbeddingModality.image});
      await images.load();
      await expectLater(
        images.embed(
          EmbeddingInput(text: 'a stop sign', images: [_png], audio: _wav()),
          TaskType.none,
        ),
        throwsA(isA<EmbeddingEngineException>()),
      );
      expect(withImages.engine.calls, hasLength(1), reason: 'the probe only');
      await images.close();
    });

    test('an audio clip reaches the engine as its own bytes, without a '
        'prefix', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime, media: {EmbeddingModality.audio});
      await pass.load();
      final clip = _wav();
      expect(
        await pass.embed(EmbeddingInput.audio(clip), TaskType.retrievalQuery),
        _unit,
      );
      final (input, options) = runtime.engine.calls.last;
      expect((input as LiteRtLmWebAudio).bytes, clip);
      expect(options.normalize, isTrue);
      expect(options.insertSpecialTokens, isTrue);
      expect(
        options.inputOverflowStrategy,
        LiteRtLmWebOverflowStrategy.truncate,
      );
      await pass.close();
    });

    test('a combined input is one request of its parts in the native order: '
        'the prefixed text, the images in order, the audio', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(
        runtime,
        media: {EmbeddingModality.image, EmbeddingModality.audio},
      );
      await pass.load();
      final second = Uint8List.fromList([..._png, 9]);
      final clip = _wav(50);
      expect(
        await pass.embed(
          EmbeddingInput(text: 'a trip', images: [_png, second], audio: clip),
          TaskType.retrievalDocument,
        ),
        _unit,
      );
      final parts = (runtime.engine.calls.last.$1 as LiteRtLmWebParts).parts;
      expect(parts, hasLength(4));
      expect(
        (parts[0] as LiteRtLmWebText).text,
        '${TaskType.retrievalDocument.prefix}a trip',
      );
      expect((parts[1] as LiteRtLmWebImage).bytes, _png);
      expect((parts[2] as LiteRtLmWebImage).bytes, second);
      expect((parts[3] as LiteRtLmWebAudio).bytes, clip);

      // Two parts of one kind are a combined input too; one part alone is
      // sent as it is.
      await pass.embed(EmbeddingInput(images: [_png, second]), TaskType.none);
      expect(
        (runtime.engine.calls.last.$1 as LiteRtLmWebParts).parts,
        hasLength(2),
      );
      await pass.embed(EmbeddingInput(text: 'x', audio: clip), TaskType.none);
      expect(
        [
          for (final p
              in (runtime.engine.calls.last.$1 as LiteRtLmWebParts).parts)
            p.runtimeType,
        ],
        [LiteRtLmWebText, LiteRtLmWebAudio],
      );
      await pass.embed(EmbeddingInput(text: 'x'), TaskType.none);
      expect(runtime.engine.calls.last.$1, isA<LiteRtLmWebText>());
      await pass.close();
    });

    test('an audio clip or a combined input over the limit is '
        'EmbeddingInputTooLongException with the engine\'s exact counts, media '
        'tokens included — cut (truncatedLength) or split into windows '
        '(WebGPU); nothing returned, the pass keeps working', () async {
      for (final webGpu in [false, true]) {
        final runtime = _FakeRuntime()..webGpu = webGpu;
        final pass = _pass(
          runtime,
          media: {EmbeddingModality.image, EmbeddingModality.audio},
        );
        await pass.load();
        // 1022 + BOS and EOS: exactly the limit.
        expect(
          await pass.embed(EmbeddingInput.audio(_wav(1022)), TaskType.none),
          _unit,
        );
        for (final (input, tokens) in [
          (EmbeddingInput.audio(_wav(1500)), 1502),
          (
            EmbeddingInput(text: 'x' * 200, images: [_png], audio: _wav(700)),
            200 + _imageTokens + 700 + 2,
          ),
        ]) {
          await expectLater(
            pass.embed(input, TaskType.none),
            throwsA(
              isA<EmbeddingInputTooLongException>()
                  .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
                  .having((e) => e.actualTokens, 'actualTokens', tokens)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains('$tokens tokens long'),
                      contains('25 per second of audio'),
                      contains('split the input'),
                    ),
                  ),
            ),
            reason: webGpu ? 'split' : 'cut',
          );
        }
        expect(
          await pass.embed(EmbeddingInput.audio(_wav()), TaskType.none),
          _unit,
        );
        await pass.close();
      }
    });

    test('an audio clip the engine fails on (miniaudio refusing it) is '
        'EmbeddingEngineException with the runtime\'s message', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime, media: {EmbeddingModality.audio});
      await pass.load();
      runtime.computeError = StateError(
        'UNKNOWN: Failed to initialize decoder',
      );
      await expectLater(
        pass.embed(EmbeddingInput.audio(_wav()), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', liteRtLmEngineTag)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('could not embed the audio clip'),
                  contains('Failed to initialize decoder'),
                ),
              ),
        ),
      );
      runtime.computeError = null;
      expect(
        await pass.embed(EmbeddingInput.audio(_wav()), TaskType.none),
        _unit,
      );
      await pass.close();
    });

    test('an image the engine fails on is EmbeddingEngineException with the '
        'runtime\'s message; a cut image is never "too long"', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime, media: {EmbeddingModality.image});
      await pass.load();
      runtime.computeError = StateError('INVALID_ARGUMENT: outofdata');
      await expectLater(
        pass.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', liteRtLmEngineTag)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('image'), contains('outofdata')),
              ),
        ),
      );
      runtime
        ..computeError = null
        ..maxSignature = 100;
      await expectLater(
        pass.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(isA<EmbeddingEngineException>()),
      );
      await pass.close();
    });

    test('a vector with NaN or only zeros, or of the wrong length, is '
        'EmbeddingEngineException', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime);
      await pass.load();
      for (final vector in [
        [double.nan, 0.5, 0.5, 0.5],
        [0.0, 0.0, 0.0, 0.0],
        [0.5, 0.5, 0.5],
      ]) {
        runtime.vectorFor = (_) => vector;
        await expectLater(
          pass.embed(EmbeddingInput.text('x'), TaskType.none),
          throwsA(isA<EmbeddingEngineException>()),
        );
      }
      await pass.close();
    });

    test('close deletes the engine once; embed after it fails', () async {
      final runtime = _FakeRuntime();
      final pass = _pass(runtime);
      await pass.load();
      await pass.close();
      await pass.close();
      expect(runtime.engine.deletes, 1);
      await expectLater(
        pass.embed(EmbeddingInput.text('x'), TaskType.none),
        throwsA(isA<EmbeddingEngineException>()),
      );
    });
  });

  test('through core\'s inline host: the model reports {text, image}, the '
      'limit and GPU; a WebP is refused on the caller before the engine sees '
      'it; text overflows with exact counts', () async {
    final runtime = _FakeRuntime();
    final host = await inline.startEmbeddingHost(
      EmbeddingPassDescriptor<LiteRtLmWebEmbeddingConfig>(
        engineTag: liteRtLmEngineTag,
        factory: buildLiteRtLmWebEmbeddingPass,
        config: _config(runtime, media: {EmbeddingModality.image}),
        activeBackend: PreferredBackend.gpu,
      ),
      declaredMedia: {EmbeddingModality.image},
      label: 'embeddinggemma-2-text-vision-440m.litertlm',
    );
    final model = CommonEmbeddingModel.withHost(
      host,
      engine: liteRtLmEngineTag,
      activeBackend: PreferredBackend.gpu,
    );
    try {
      expect(model.dimension, 4);
      expect(model.maxInputTokens, 1024);
      expect(model.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });
      expect(model.activeBackend, PreferredBackend.gpu);
      final calls = runtime.engine.calls.length;
      await expectLater(
        model.embed(EmbeddingInput.image(_webp), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>().having(
            (e) => e.detected,
            'detected',
            EncodedMediaFormat.webp,
          ),
        ),
      );
      expect(runtime.engine.calls, hasLength(calls), reason: 'never sent');
      expect(
        await model.embed(EmbeddingInput.image(_png), taskType: TaskType.none),
        _unit,
      );
      await expectLater(
        model.embed(
          EmbeddingInput.text('w' * 1100),
          taskType: TaskType.retrievalDocument,
        ),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having(
                (e) => e.actualTokens,
                'actualTokens',
                TaskType.retrievalDocument.prefix.length + 1100 + 2,
              ),
        ),
      );
    } finally {
      await model.close();
    }
    expect(runtime.engine.deletes, 1);
  });

  test('through core\'s inline host, audio and images declared: '
      '{text, image, audio}; a combined input passes the D17 gate and reaches '
      'the engine as one request; an M4A clip is refused on the caller before '
      'the engine sees it', () async {
    final runtime = _FakeRuntime();
    final media = {EmbeddingModality.image, EmbeddingModality.audio};
    final host = await inline.startEmbeddingHost(
      EmbeddingPassDescriptor<LiteRtLmWebEmbeddingConfig>(
        engineTag: liteRtLmEngineTag,
        factory: buildLiteRtLmWebEmbeddingPass,
        config: _config(runtime, media: media),
        activeBackend: PreferredBackend.gpu,
      ),
      declaredMedia: media,
      label: 'embeddinggemma-2-740m.litertlm',
    );
    final model = CommonEmbeddingModel.withHost(
      host,
      engine: liteRtLmEngineTag,
      activeBackend: PreferredBackend.gpu,
    );
    try {
      expect(model.modalities, EmbeddingModality.values.toSet());
      final calls = runtime.engine.calls.length;
      await expectLater(
        model.embed(EmbeddingInput.audio(_m4a), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingFormatNotSupportedException>()
              .having((e) => e.detected, 'detected', EncodedMediaFormat.m4a)
              .having((e) => e.accepted, 'accepted', liteRtLmAudioFormats),
        ),
      );
      expect(runtime.engine.calls, hasLength(calls), reason: 'never sent');
      expect(
        await model.embed(
          EmbeddingInput(text: 'a trip', images: [_png], audio: _wav()),
          taskType: TaskType.retrievalDocument,
        ),
        _unit,
      );
      expect(
        (runtime.engine.calls.last.$1 as LiteRtLmWebParts).parts,
        hasLength(3),
      );
      await expectLater(
        model.embed(EmbeddingInput.audio(_wav(1500)), taskType: TaskType.none),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 1502),
        ),
      );
    } finally {
      await model.close();
    }
    expect(runtime.engine.deletes, 1);
  });
}

// The EmbeddingGemma 2 `.litertlm` pass over FAKE LiteRT-LM bindings (R5
// §4.8, §4.10, D21-D23): what it reads from ModelInfo and when, what it hands
// the settings, how a native failure becomes a typed exception, and that every
// native object and every Dart allocation it makes is freed on every path —
// success, and failure at each step.
//
// The fake extends the generated bindings with a lookup that throws, so a call
// the fake does not model fails the test instead of reaching a native library.

// ignore_for_file: non_constant_identifier_names

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/embedding_parts.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litert_lm_embedding_pass.dart';
import 'package:flutter_edge_ai_litertlm/src/embedding/litertlm_npu_target.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_embedding_bindings.dart';
import 'package:flutter_test/flutter_test.dart';

const _file = 'eg2.litertlm';
const _noAudioEncoder =
    '$_file has no audio encoder; install embeddinggemma-2-740m';
const _allSignatures = [128, 256, 512, 1024, 2048, 8192];

/// What a per-SoC bundle declares (measured: 128-1024, no 2048/8192).
const _npuSignatures = [128, 256, 512, 1024];
const _sm8850 = LiteRtLmNpuTarget(vendor: 'Qualcomm', soc: 'SM8850');
const _dispatchDir = '/data/app/code_cache/litert_npu';

/// What LiteRT-LM's stb decoder handles (X3, measured on our dylib).
final _imageFormats = {
  EncodedMediaFormat.jpeg,
  EncodedMediaFormat.png,
  EncodedMediaFormat.gif,
  EncodedMediaFormat.bmp,
};

/// What LiteRT-LM's miniaudio decoder handles (measured on the 740m).
final _audioFormats = {
  EncodedMediaFormat.wav,
  EncodedMediaFormat.mp3,
  EncodedMediaFormat.flac,
};

/// The container headers of real bundles (test/ffi/fixtures/README.md): the
/// pass reads the section table for audio support (D23).
const _header440m = 'test/ffi/fixtures/embeddinggemma2_440m_header.litertlm';
const _header740m = 'test/ffi/fixtures/embeddinggemma2_740m_header.litertlm';

/// The start of a WAV file: not valid UTF-8 past the header, so a pass that
/// sent it as text would fail loudly in the fake.
final _wav = Uint8List.fromList([
  ...'RIFF'.codeUnits, 0x24, 0, 0, 0, ...'WAVE'.codeUnits, //
  0xFF, 0xFE, 0x80, 0x81,
]);

/// The start of a PNG: enough for the sniff, and not valid UTF-8, so a pass
/// that sent it as text would fail loudly in the fake.
final _png = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0xFF, 0xFE, 0x80, 0x81,
]);

void main() {
  late Directory root;
  late String modelPath;
  late String cacheBase;
  late _FakeLiteRtLm native;
  late _CountingAllocator allocator;

  setUp(() {
    root = Directory.systemTemp.createTempSync('eg2_pass_test_');
    modelPath = '${root.path}/models/$_file';
    File(modelPath)
      ..createSync(recursive: true)
      ..writeAsBytesSync(List.filled(37, 7));
    cacheBase = '${root.path}/cache/flutter_edge_ai/emb';
    native = _FakeLiteRtLm();
    allocator = _CountingAllocator();
  });

  tearDown(() {
    native.dispose();
    root.deleteSync(recursive: true);
  });

  LiteRtLmEmbeddingPass pass({
    Set<EmbeddingModality> declaredMedia = const {},
    int? numThreads,
    int visionTokensPerImage = 140,
    LiteRtLmEmbeddingBindings Function()? openBindings,
    DateTime Function()? clock,
    LiteRtLmNpuTarget? npuTarget,
  }) => LiteRtLmEmbeddingPass(
    LiteRtLmEmbeddingConfig(
      modelPath: modelPath,
      cacheBase: cacheBase,
      declaredMedia: declaredMedia,
      numThreads: numThreads,
      visionTokensPerImage: visionTokensPerImage,
      npuTarget: npuTarget,
      npuDispatchDir: npuTarget == null ? null : _dispatchDir,
    ),
    openBindings: openBindings ?? () => native,
    allocator: allocator,
    clock: clock,
  );

  /// A clock an hour ahead: every directory made so far is older than the
  /// 10-minute grace.
  DateTime anHourLater() => DateTime.now().add(const Duration(hours: 1));

  String expectedCacheDir() {
    final stat = File(modelPath).statSync();
    return '$cacheBase/${liteRtLmCacheDirPrefix(_file)}-'
        '${stat.size.toRadixString(36)}-'
        '${stat.modified.millisecondsSinceEpoch.toRadixString(36)}';
  }

  /// Every native object created was deleted, and every Dart allocation freed.
  void expectNothingLeaked() {
    expect(native.live, isEmpty, reason: 'native objects still alive');
    expect(allocator.live, 0, reason: 'leaked ${allocator.live} pointer(s)');
  }

  group('load', () {
    test(
      'reads ModelInfo, frees it, then settings → engine → options',
      () async {
        final info = await pass().load();

        expect(info.dimension, 4);
        expect(info.modalities, {EmbeddingModality.text});
        expect(info.maxInputTokens, 1024);
        expect(info.imageFormats, isEmpty);
        expect(info.audioFormats, isEmpty);
        expect(
          info.combinedInputs,
          isTrue,
          reason: 'one vector may carry text, images and audio together',
        );

        expect(native.loadedPath, modelPath);
        expect(
          native.order,
          containsAllInOrder([
            'loaded_file_create',
            'loaded_file_delete',
            'settings_create',
            'settings_set_cache_dir',
            'settings_set_max_input_length',
            'engine_create',
            'settings_delete',
            'options_create',
          ]),
          reason:
              'ModelInfo is read and freed before any settings exist, and '
              'the settings are freed right after the engine copied them',
        );
        expect(native.settingsModelPath, modelPath);
        expect(native.settingsBackend, 'cpu');
        expect(
          native.towerBackendsNull,
          isTrue,
          reason:
              'NULL tower backends: present towers run on the main '
              'backend, and "cpu" for an absent one fails create (D26)',
        );
        expect(native.live.keys, unorderedEquals(['engine', 'options']));
        expect(allocator.live, 0);
      },
    );

    test(
      'the settings always get the engine-owned cache dir and 1024',
      () async {
        await pass().load();
        expect(native.cacheDir, expectedCacheDir());
        expect(Directory(expectedCacheDir()).existsSync(), isTrue);
        expect(native.maxInputLength, 1024);
      },
    );

    test('options: normalize and special tokens on, overflow kTruncate (the '
        'P3 gate: exact counts from the response), no output size', () async {
      await pass().load();
      expect(native.normalize, isTrue);
      expect(native.insertSpecialTokens, isTrue);
      expect(
        native.overflowStrategy,
        LiteRtLmInputOverflowStrategy.kLiteRtLmInputOverflowStrategyTruncate,
      );
      expect(native.order, isNot(contains('options_set_output_size')));
    });

    test('the overflow strategy values are the header\'s 0/1/2', () {
      expect(
        LiteRtLmInputOverflowStrategy
            .kLiteRtLmInputOverflowStrategyChunkAndAverage
            .value,
        0,
      );
      expect(
        LiteRtLmInputOverflowStrategy
            .kLiteRtLmInputOverflowStrategyTruncate
            .value,
        1,
      );
      expect(
        LiteRtLmInputOverflowStrategy.kLiteRtLmInputOverflowStrategyError.value,
        2,
      );
    });

    test('threads are set only when the config asks', () async {
      await pass().load();
      expect(native.order, isNot(contains('settings_set_num_threads')));

      native.dispose();
      native = _FakeLiteRtLm();
      await pass(numThreads: 2).load();
      expect(native.numThreads, 2);
    });

    group('maxInputTokens is the smallest text signature at or above the '
        'setting (1024, or the largest signature below it)', () {
      for (final (signatures, setting, max) in [
        (_allSignatures, 1024, 1024),
        ([8192, 128, 2048, 512, 1024, 256], 1024, 1024),
        ([128, 256, 2048], 1024, 2048),
        ([128, 256, 512], 512, 512),
        ([4096], 1024, 4096),
      ]) {
        test('$signatures → setting $setting, maxInputTokens $max', () async {
          native.textSignatures = signatures;
          final info = await pass().load();
          expect(native.maxInputLength, setting);
          expect(info.maxInputTokens, max);
        });
      }
    });

    group('refused from ModelInfo, before any settings or engine', () {
      Future<void> expectRefusal(Object message, {int? nativeCode}) async {
        final p = pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT-LM')
                .having((e) => e.message, 'message', message)
                .having((e) => e.nativeCode, 'nativeCode', nativeCode),
          ),
        );
        expect(native.created('settings'), 0);
        expect(native.created('engine'), 0);
        expectNothingLeaked();
        await p.close();
        expectNothingLeaked();
      }

      test('an LLM bundle', () async {
        native.modelType = LiteRtLmModelType.kLiteRtLmModelTypeLlm;
        await expectRefusal(
          startsWith(
            '$_file is an LLM bundle, not an '
            'embedder',
          ),
        );
      });

      test('a bundle of unknown type', () async {
        native.modelType = LiteRtLmModelType.kLiteRtLmModelTypeUnknown;
        await expectRefusal(contains('not a LiteRT-LM embedding bundle'));
      });

      test('no dimension', () async {
        native.dimension = -1;
        await expectRefusal(contains('dimension'));
      });

      test('no text signature', () async {
        native.textSignatures = null;
        await expectRefusal(contains('text signature'));
        native.textSignatures = const [];
        await expectRefusal(contains('text signature'));
      });

      test('an unreadable file: the native code and message', () async {
        native.failLoadedFile = (code: 5, message: 'No such file: x');
        await expectRefusal(
          allOf(contains(_file), contains('No such file: x')),
          nativeCode: 5,
        );
        expect(native.created('loaded_file'), 0);
      });
    });

    group('capabilities come from the vision signatures (D23)', () {
      Future<void> expectMediaRefusal(
        Set<EmbeddingModality> declared,
        Object message, {
        int visionTokensPerImage = 140,
      }) async {
        final p = pass(
          declaredMedia: declared,
          visionTokensPerImage: visionTokensPerImage,
        );
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT-LM')
                .having((e) => e.message, 'message', message),
          ),
        );
        expect(
          native.created('settings'),
          0,
          reason: 'refused from ModelInfo: no engine, so no tower cache',
        );
        expect(
          Directory(cacheBase).existsSync(),
          isFalse,
          reason: 'refused before the cache directory exists',
        );
        expectNothingLeaked();
        await p.close();
      }

      test('images on a bundle without vision signatures name the 440m '
          'bundle', () async {
        native.visionSignatures = null; // -1, as the 270m reports
        await expectMediaRefusal(
          {EmbeddingModality.image},
          '$_file has no vision encoder; install '
          'embeddinggemma-2-text-vision-440m',
        );
        native.visionSignatures = const []; // an empty list: no tower either
        await expectMediaRefusal({
          EmbeddingModality.image,
        }, contains('has no vision encoder'));
      });

      test('images on a bundle with vision: text and images, the formats '
          'stb decodes, and the budget handed to the settings', () async {
        native.visionSignatures = const [70, 140];
        final info = await pass(
          declaredMedia: {EmbeddingModality.image},
        ).load();
        expect(info.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
        });
        expect(info.imageFormats, _imageFormats);
        expect(info.audioFormats, isEmpty);
        expect(info.combinedInputs, isTrue);
        expect(native.visionTokensPerImage, 140);
        expect(
          native.order,
          containsAllInOrder([
            'settings_create',
            'settings_set_vision_tokens_per_image',
            'engine_create',
          ]),
          reason: 'the budget is a setting the engine copies at create',
        );
        expect(native.towerBackendsNull, isTrue, reason: 'D26: NULL towers');
      });

      test('70 is the opt-in budget', () async {
        native.visionSignatures = const [70, 140];
        await pass(
          declaredMedia: {EmbeddingModality.image},
          visionTokensPerImage: 70,
        ).load();
        expect(native.visionTokensPerImage, 70);
      });

      test('a budget the bundle has no vision signature for is refused from '
          'ModelInfo, naming the ones it has', () async {
        native.visionSignatures = const [140];
        await expectMediaRefusal(
          {EmbeddingModality.image},
          allOf(contains(_file), contains('70'), contains('140')),
          visionTokensPerImage: 70,
        );
      });

      test('audio on a bundle without an audio encoder (the 440m container, '
          'whose ModelInfo claims audio) names the 740m bundle', () async {
        File(_header440m).copySync(modelPath);
        native.visionSignatures = const [70, 140];
        await expectMediaRefusal({EmbeddingModality.audio}, _noAudioEncoder);
        await expectMediaRefusal({
          EmbeddingModality.image,
          EmbeddingModality.audio,
        }, _noAudioEncoder);
      });

      test('audio on a bundle with an audio encoder (the 740m container): '
          'text, images and audio, the formats miniaudio decodes, combined '
          'inputs', () async {
        File(_header740m).copySync(modelPath);
        native.visionSignatures = const [70, 140];
        final info = await pass(
          declaredMedia: {EmbeddingModality.image, EmbeddingModality.audio},
        ).load();
        expect(info.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
          EmbeddingModality.audio,
        });
        expect(info.imageFormats, _imageFormats);
        expect(info.audioFormats, _audioFormats);
        expect(info.combinedInputs, isTrue);
        expect(native.towerBackendsNull, isTrue, reason: 'D26: NULL towers');

        native.dispose();
        native = _FakeLiteRtLm()..visionSignatures = const [70, 140];
        final audioOnly = await pass(
          declaredMedia: {EmbeddingModality.audio},
        ).load();
        expect(audioOnly.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
          EmbeddingModality.audio,
        });
        expect(
          native.order,
          isNot(contains('settings_set_vision_tokens_per_image')),
          reason: 'images were not declared',
        );
      });

      test('a container it cannot read, with audio declared, is a load '
          'failure — never "no audio" — before anything is created', () async {
        // modelPath holds 37 bytes of 7s: ModelInfo is faked, the container
        // is real and has no LITERTLM magic.
        await expectMediaRefusal(
          {EmbeddingModality.audio},
          allOf(
            contains('could not read the container of $_file'),
            contains('LITERTLM'),
          ),
        );
      });

      test('the container is read only when audio is declared: a text or '
          'image load never depends on it', () async {
        // The same unreadable container as above.
        native.visionSignatures = const [70, 140];
        final info = await pass(
          declaredMedia: {EmbeddingModality.image},
        ).load();
        expect(info.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
        });
        expect(info.audioFormats, isEmpty);
      });

      test('the audio formats are the ones measured decoding: Ogg and M4A '
          'fail in miniaudio, so core refuses them before sending', () {
        expect(liteRtLmAudioFormats, _audioFormats);
        expect(liteRtLmAudioFormats, isNot(contains(EncodedMediaFormat.ogg)));
        expect(liteRtLmAudioFormats, isNot(contains(EncodedMediaFormat.m4a)));
      });

      test('a vision bundle used for text only: the engine still reports '
          'images (core keeps the model at what was declared), and the budget '
          'is not set', () async {
        native.visionSignatures = const [70, 140];
        final info = await pass().load();
        expect(info.modalities, {
          EmbeddingModality.text,
          EmbeddingModality.image,
        });
        expect(info.imageFormats, _imageFormats);
        expect(
          native.order,
          isNot(contains('settings_set_vision_tokens_per_image')),
        );
      });

      test('a text-only bundle reports text, and no formats', () async {
        native.visionSignatures = null;
        final info = await pass().load();
        expect(info.modalities, {EmbeddingModality.text});
        expect(info.imageFormats, isEmpty);
      });

      test('the formats are the ones X3 measured decoding: WebP, TIFF and '
          'HEIC are not among them, so core refuses them before sending', () {
        expect(liteRtLmImageFormats, _imageFormats);
        for (final refused in [
          EncodedMediaFormat.webp,
          EncodedMediaFormat.tiff,
          EncodedMediaFormat.heic,
          EncodedMediaFormat.avif,
        ]) {
          expect(liteRtLmImageFormats, isNot(contains(refused)));
        }
      });
    });

    group('a failure at each step frees everything created before it', () {
      test('the library does not open', () async {
        final p = pass(openBindings: () => throw ArgumentError('dlopen: gone'));
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.engine, 'engine', 'LiteRT-LM')
                .having((e) => e.cause, 'cause', isA<ArgumentError>()),
          ),
        );
        await p.close();
        expect(native.order, isEmpty);
        expectNothingLeaked();
      });

      test('settings_create', () async {
        native.failSettings = (code: 3, message: 'bad model file');
        final p = pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.nativeCode, 'nativeCode', 3)
                .having((e) => e.message, 'message', contains('bad model file'))
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('cache directory')),
                ),
          ),
        );
        expectNothingLeaked();
        await p.close();
        expectNothingLeaked();
      });

      test(
        'engine_create with code 3: the cache dir, not an overflow',
        () async {
          native.failEngine = (code: 3, message: 'cannot write cache');
          final p = pass();
          await expectLater(
            p.load(),
            throwsA(
              isA<EmbeddingLoadException>()
                  .having((e) => e.nativeCode, 'nativeCode', 3)
                  .having(
                    (e) => e.message,
                    'message',
                    allOf(
                      contains(
                        'embedding cache directory ${expectedCacheDir()}',
                      ),
                      contains('not writable'),
                      contains('cannot write cache'),
                    ),
                  ),
            ),
          );
          expect(native.deleted('settings'), 1);
          expectNothingLeaked();
          await p.close();
          expectNothingLeaked();
        },
      );

      test('engine_create with another code', () async {
        native.failEngine = (code: 13, message: 'tensor alloc failed');
        final p = pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.nativeCode, 'nativeCode', 13)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('tensor alloc failed'),
                    isNot(contains('cache directory')),
                  ),
                ),
          ),
        );
        expectNothingLeaked();
        await p.close();
        expectNothingLeaked();
      });

      test('engine_create returning NULL with nothing reported is not the '
          'cache dir, whatever an earlier call left', () async {
        // Left on the thread after the settings were made: a setter that
        // reported something (upstream main's setters return statuses).
        native
          ..errorFromSetter = (code: 3, message: 'left by a setter')
          ..silentNullEngine = true;
        final p = pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>()
                .having((e) => e.nativeCode, 'nativeCode', isNull)
                .having(
                  (e) => e.message,
                  'message',
                  isNot(contains('cache directory')),
                ),
          ),
        );
        expectNothingLeaked();
        await p.close();
      });

      test('options_create', () async {
        native.failOptions = true;
        final p = pass();
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        expect(native.deleted('engine'), 1);
        expectNothingLeaked();
        await p.close();
        expectNothingLeaked();
      });
    });

    group('the engine-owned cache directory (D22)', () {
      test(
        'is created, and the caches of earlier copies of the same file name '
        '(a re-download, a new revision under the same name) are deleted',
        () async {
          final ours = liteRtLmCacheDirPrefix(_file);
          final size = File(modelPath).lengthSync();
          final staleDirs = [
            Directory('$cacheBase/$ours-1-2'), // other size and time
            Directory('$cacheBase/$ours-2q0ikg-mv4esplh'), // base 36 letters
            // Same size, older time.
            Directory('$cacheBase/$ours-${size.toRadixString(36)}-2'),
          ];
          for (final stale in staleDirs) {
            stale.createSync(recursive: true);
            File('${stale.path}/old.xnnpack_cache').writeAsStringSync('x');
          }
          final kept = [
            Directory(
              '$cacheBase/${liteRtLmCacheDirPrefix('other.litertlm')}-1-2',
            ),
            Directory('$cacheBase/$ours-ABC-2'),
            Directory('$cacheBase/$ours-a_b-2'),
            Directory('$cacheBase/$ours-1-2-3'),
            Directory('$cacheBase/x$ours-1-2'),
            Directory('$cacheBase/$_file-1-2'),
          ];
          for (final dir in kept) {
            dir.createSync(recursive: true);
          }

          await pass(clock: anHourLater).load();

          expect(Directory(expectedCacheDir()).existsSync(), isTrue);
          for (final stale in staleDirs) {
            expect(stale.existsSync(), isFalse, reason: stale.path);
          }
          for (final dir in kept) {
            expect(dir.existsSync(), isTrue, reason: '${dir.path} is not ours');
          }
        },
      );

      test('stale siblings go only after this pass\'s engine was created: a '
          'failed create deletes nothing', () async {
        final stale = Directory(
          '$cacheBase/${liteRtLmCacheDirPrefix(_file)}-1-2',
        )..createSync(recursive: true);
        native.failEngine = (code: 13, message: 'no engine');
        final p = pass(clock: anHourLater);
        await expectLater(p.load(), throwsA(isA<EmbeddingLoadException>()));
        await p.close();
        expect(stale.existsSync(), isTrue);

        native.dispose();
        native = _FakeLiteRtLm();
        await pass(clock: anHourLater).load();
        expect(stale.existsSync(), isFalse);
      });

      test('a sibling touched within the last 10 minutes is kept — another '
          'process may be loading that copy', () async {
        final ours = liteRtLmCacheDirPrefix(_file);
        // Just made: its directory is fresh.
        final fresh = Directory('$cacheBase/$ours-1-2')
          ..createSync(recursive: true);
        // Old directory, but an entry inside was written 5 minutes "ago".
        final busy = Directory('$cacheBase/$ours-3-4')
          ..createSync(recursive: true);
        final clock = anHourLater();
        File('${busy.path}/model.text_encoder.xnnpack_cache')
          ..writeAsStringSync('being written')
          ..setLastModifiedSync(clock.subtract(const Duration(minutes: 5)));

        await pass().load(); // the real clock: `fresh` is seconds old
        expect(fresh.existsSync(), isTrue);

        await pass(clock: () => clock).load();
        expect(fresh.existsSync(), isFalse, reason: 'an hour old by now');
        expect(busy.existsSync(), isTrue, reason: 'its newest entry is fresh');
      });

      test('a sibling that will not delete is logged, not fatal, and does not '
          'stop the others', () async {
        final ours = liteRtLmCacheDirPrefix(_file);
        final stuck = Directory('$cacheBase/$ours-1-2/locked')
          ..createSync(recursive: true);
        File('${stuck.path}/x').writeAsStringSync('x');
        // Sorts after the stuck one, so it is tried after the failure.
        final other = Directory('$cacheBase/$ours-5-6')
          ..createSync(recursive: true);
        Process.runSync('chmod', ['555', stuck.path]);
        addTearDown(() => Process.runSync('chmod', ['755', stuck.path]));

        final info = await pass(clock: anHourLater).load();
        expect(info.dimension, 4);
        expect(other.existsSync(), isFalse);
      }, skip: Platform.isWindows ? 'chmod' : null);

      test('is named <8-hex hash of the file name>-<base36 size>-<base36 '
          'mtime ms>', () {
        final name = liteRtLmCacheDirName(
          _file,
          size: 164626432,
          modified: DateTime.fromMillisecondsSinceEpoch(1791758581397),
        );
        // 164626432 = 2q0ikg, 1791758581397 = mv4esplh in base 36.
        expect(name, matches(RegExp(r'^[0-9a-f]{8}-2q0ikg-mv4esplh$')));
        expect(name, hasLength(24));
        expect(name, startsWith(liteRtLmCacheDirPrefix(_file)));
        expect(
          liteRtLmCacheDirPrefix('a.litertlm'),
          isNot(liteRtLmCacheDirPrefix('b.litertlm')),
        );
      });

      test('keeps the engine\'s cache file well under Windows MAX_PATH for '
          'the example app', () {
        // The engine names its file `<model>_<mtime s>_<size>.<graph>.xnnpack_cache`
        // inside the directory; spelling the model's name in the directory
        // too put this path at about 284 characters.
        const model = 'embeddinggemma-2-text-270m__rev-9be6e8b90982.litertlm';
        // getApplicationCacheDirectory() on Windows: %LOCALAPPDATA%\<company>
        // \<product>.
        const base =
            r'C:\Users\a-twenty-char-user-x\AppData\Local\dev.flutterberlin'
            r'\flutter_edge_ai_example\flutter_edge_ai\emb';
        final dir = liteRtLmCacheDirName(
          model,
          size: 164626432,
          modified: DateTime.fromMillisecondsSinceEpoch(1791758581397),
        );
        final file = '${model}_1791758581_164626432.text_encoder.xnnpack_cache';
        final path = '$base\\$dir\\$file';
        // 232 characters: 28 to spare for a longer user, company or app
        // folder (the 12-hex / decimal / embedding_cache form left 4).
        expect(path.length, 232);
        expect(260 - path.length, greaterThanOrEqualTo(25));
      });

      test('an empty directory after create is reported, a filled one is '
          'not', () async {
        Future<List<String>> printsDuring(Future<void> Function() body) async {
          final lines = <String>[];
          await runZoned(
            body,
            zoneSpecification: ZoneSpecification(
              print: (_, _, _, line) => lines.add(line),
            ),
          );
          return lines;
        }

        final filled = await printsDuring(() => pass().load());
        expect(filled.where((l) => l.contains('weight cache')), isEmpty);

        native.dispose();
        native = _FakeLiteRtLm()..writeCacheOnCreate = false;
        Directory(expectedCacheDir()).deleteSync(recursive: true);
        final empty = await printsDuring(() => pass().load());
        expect(
          empty,
          contains(
            allOf(
              contains('WARNING'),
              contains('no weight cache'),
              contains(expectedCacheDir()),
            ),
          ),
        );
      });

      test('a path that cannot become a directory is a load failure, before '
          'any settings', () async {
        File(cacheBase)
          ..createSync(recursive: true)
          ..writeAsStringSync('a file where the cache base should be');
        final p = pass();
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              contains('embedding cache directory'),
            ),
          ),
        );
        expect(native.created('settings'), 0);
        expectNothingLeaked();
        await p.close();
      });
    });
  });

  group('embed', () {
    late LiteRtLmEmbeddingPass p;

    setUp(() async {
      p = pass();
      await p.load();
    });

    tearDown(() => p.close());

    test('sends taskType.prefix + text as ONE text part, for every '
        'TaskType', () async {
      for (final taskType in TaskType.values) {
        final vector = await p.embed(
          EmbeddingInput.text('Привет, мир 🌍'),
          taskType,
        );
        expect(vector, native.lastVector);
        expect(native.lastTexts, ['${taskType.prefix}Привет, мир 🌍']);
        expect(native.lastPartTypes, [
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
        ]);
      }
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test(
      'empty text with no prefix is an empty part (BOS and EOS only)',
      () async {
        await p.embed(EmbeddingInput.text(''), TaskType.none);
        expect(native.lastTexts, ['']);
        expect(allocator.live, 0);
      },
    );

    test('a truncated response is EmbeddingInputTooLongException with the '
        'exact counts the response reports; the vector is never returned, '
        'the response is deleted and the engine keeps working', () async {
      native
        ..responseInputLength = 2402
        ..responseTruncatedLength = 1024;
      await expectLater(
        p.embed(EmbeddingInput.text('long'), TaskType.retrievalDocument),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 2402)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('2402'), contains('1024'), contains(_file)),
              ),
        ),
      );
      expect(
        native.order,
        containsAllInOrder([
          'compute_embedding',
          'response_get_input_length',
          'response_get_truncated_length',
          'response_delete',
        ]),
      );
      expect(native.order, isNot(contains('response_get_values')));
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);

      native
        ..responseInputLength = 12
        ..responseTruncatedLength = 0;
      expect(
        await p.embed(EmbeddingInput.text('short'), TaskType.retrievalQuery),
        native.lastVector,
      );
    });

    test('code 3 is no longer an overflow (kTruncate returns a response for '
        'one): EmbeddingEngineException(nativeCode 3)', () async {
      native.failCompute = (code: 3, message: 'Some structural problem');
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalDocument),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', 3)
              .having(
                (e) => e.message,
                'message',
                contains('Some structural problem'),
              ),
        ),
      );
      expect(allocator.live, 0);
    });

    test('a count past the limit with nothing reported truncated is still an '
        'overflow, against the limit read at load — never a vector', () async {
      native
        ..responseInputLength = 1500
        ..responseTruncatedLength = 0;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 1500),
        ),
      );
      native.responseInputLength = 1024; // exactly the limit: embedded
      expect(
        await p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        native.lastVector,
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('a response without token counts (-1) is an engine failure, never '
        'a vector', () async {
      native.responseInputLength = -1;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(isA<EmbeddingEngineException>()),
      );
      native
        ..responseInputLength = 12
        ..responseTruncatedLength = -1;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(isA<EmbeddingEngineException>()),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('any other code is EmbeddingEngineException(nativeCode) with the '
        'message read before any other native call', () async {
      native.failCompute = (code: 13, message: 'Vision executor missing');
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having((e) => e.nativeCode, 'nativeCode', 13)
              .having(
                (e) => e.message,
                'message',
                contains('Vision executor missing'),
              ),
        ),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('a NULL that reports nothing is not read as an earlier failure on '
        'this thread', () async {
      native
        ..setStaleError(3, 'an overflow from an earlier call')
        ..silentNullCompute = true;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', isNull)
              .having(
                (e) => e.message,
                'message',
                contains('no error reported'),
              ),
        ),
      );
    });

    test('input_data_create returning NULL sets no native error: an engine '
        'failure without a code', () async {
      native.failInputData = true;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.nativeCode,
            'nativeCode',
            isNull,
          ),
        ),
      );
      expect(native.order, isNot(contains('compute_embedding')));
      expect(allocator.live, 0);
    });

    test('an image on a pass loaded without images never reaches the engine '
        '(core refuses it first; reaching the pass is a host bug)', () async {
      await expectLater(
        p.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(isA<EmbeddingEngineException>()),
      );
      expect(native.order, isNot(contains('input_data_create')));
      expect(allocator.live, 0);
    });

    test('a vector of the wrong size fails, and the response is still '
        'deleted', () async {
      native.responseSize = 3;
      await expectLater(
        p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery),
        throwsA(isA<EmbeddingEngineException>()),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });
  });

  group('embed an image', () {
    late LiteRtLmEmbeddingPass p;

    setUp(() async {
      native.visionSignatures = const [70, 140];
      p = pass(declaredMedia: {EmbeddingModality.image});
      await p.load();
    });

    tearDown(() => p.close());

    test('sends the encoded bytes as ONE image part, never a prefix, for '
        'every TaskType', () async {
      for (final taskType in TaskType.values) {
        final vector = await p.embed(EmbeddingInput.image(_png), taskType);
        expect(vector, native.lastVector);
        expect(native.lastPartTypes, [
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage,
        ]);
        expect(native.lastParts.single, _png);
      }
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('text still works on the same pass', () async {
      await p.embed(EmbeddingInput.text('a red circle'), TaskType.none);
      expect(native.lastPartTypes, [
        LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
      ]);
      expect(native.lastTexts, ['a red circle']);
    });

    test('code 3 on an image is a decode failure, never an overflow: '
        'EmbeddingEngineException(nativeCode 3), and the engine keeps '
        'working', () async {
      native.failCompute = (code: 3, message: 'Failed to decode image');
      await expectLater(
        p.embed(EmbeddingInput.image(_png), TaskType.retrievalDocument),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having((e) => e.nativeCode, 'nativeCode', 3)
              .having(
                (e) => e.message,
                'message',
                allOf(contains('decode'), contains('Failed to decode image')),
              ),
        ),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);

      native.failCompute = null;
      expect(
        await p.embed(EmbeddingInput.image(_png), TaskType.none),
        native.lastVector,
      );
    });

    test('any other code on an image is EmbeddingEngineException with that '
        'code', () async {
      native.failCompute = (code: 13, message: 'Vision executor missing');
      await expectLater(
        p.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', 13)
              .having(
                (e) => e.message,
                'message',
                contains('Vision executor missing'),
              ),
        ),
      );
      expect(allocator.live, 0);
    });

    test('input_data_create returning NULL for an image: an engine failure '
        'without a code, nothing computed', () async {
      native.failInputData = true;
      await expectLater(
        p.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.nativeCode,
            'nativeCode',
            isNull,
          ),
        ),
      );
      expect(native.order, isNot(contains('compute_embedding')));
      expect(allocator.live, 0);
    });

    test('audio never reaches the engine (core refuses it first; reaching '
        'the pass is a host bug)', () async {
      await expectLater(
        p.embed(
          EmbeddingInput.audio(Uint8List.fromList([1, 2, 3])),
          TaskType.none,
        ),
        throwsA(isA<EmbeddingEngineException>()),
      );
      expect(native.order, isNot(contains('input_data_create')));
      expect(allocator.live, 0);
    });
  });

  group('embed audio and combined inputs (the 740m)', () {
    late LiteRtLmEmbeddingPass p;

    setUp(() async {
      File(_header740m).copySync(modelPath);
      native.visionSignatures = const [70, 140];
      p = pass(
        declaredMedia: {EmbeddingModality.image, EmbeddingModality.audio},
      );
      await p.load();
    });

    tearDown(() => p.close());

    test('sends the encoded clip as ONE audio part, never a prefix, for '
        'every TaskType', () async {
      for (final taskType in TaskType.values) {
        final vector = await p.embed(EmbeddingInput.audio(_wav), taskType);
        expect(vector, native.lastVector);
        expect(native.lastPartTypes, [
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudio,
        ]);
        expect(native.lastParts.single, _wav);
      }
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('a combined input is ONE request: the prefixed text, the images in '
        'order, then the audio', () async {
      final second = Uint8List.fromList([..._png, 1]);
      for (final taskType in TaskType.values) {
        await p.embed(
          EmbeddingInput(text: 'a cat', images: [_png, second], audio: _wav),
          taskType,
        );
        expect(native.lastPartTypes, [
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeText,
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage,
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeImage,
          LiteRtLmInputDataType.kLiteRtLmInputDataTypeAudio,
        ]);
        expect(native.lastTexts, ['${taskType.prefix}a cat']);
        expect(native.lastParts.sublist(1), [_png, second, _wav]);
      }
      expect(native.created('input_data'), native.deleted('input_data'));
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('an overflow with media reports the exact counts, media tokens '
        'included', () async {
      native
        ..responseInputLength = 1504
        ..responseTruncatedLength = 1024;
      await expectLater(
        p.embed(EmbeddingInput.audio(_wav), TaskType.none),
        throwsA(
          isA<EmbeddingInputTooLongException>()
              .having((e) => e.maxInputTokens, 'maxInputTokens', 1024)
              .having((e) => e.actualTokens, 'actualTokens', 1504),
        ),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('status 2 on audio is miniaudio refusing the file: '
        'EmbeddingEngineException(nativeCode 2) naming the audio; the engine '
        'keeps working', () async {
      native.failCompute = (
        code: 2,
        message: 'Failed to initialize miniaudio decoder, error code: -10',
      );
      await expectLater(
        p.embed(EmbeddingInput.audio(_wav), TaskType.none),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', 2)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('could not decode the audio'),
                  contains('miniaudio'),
                ),
              ),
        ),
      );
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
      native.failCompute = null;
      expect(
        await p.embed(EmbeddingInput.audio(_wav), TaskType.none),
        native.lastVector,
      );
    });

    test('status 3 on a combined input with an image is the image decode '
        'failure', () async {
      native.failCompute = (code: 3, message: 'Failed to decode image');
      await expectLater(
        p.embed(
          EmbeddingInput(text: 'x', images: [_png], audio: _wav),
          TaskType.none,
        ),
        throwsA(
          isA<EmbeddingEngineException>()
              .having((e) => e.nativeCode, 'nativeCode', 3)
              .having(
                (e) => e.message,
                'message',
                contains('could not decode an image'),
              ),
        ),
      );
      expect(native.created('input_data'), 3);
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });

    test('input_data_create returning NULL for a later part: the parts made '
        'before it are deleted, nothing is computed', () async {
      native.failInputDataAt = 2; // text and image made, the audio fails
      await expectLater(
        p.embed(
          EmbeddingInput(text: 'x', images: [_png], audio: _wav),
          TaskType.none,
        ),
        throwsA(
          isA<EmbeddingEngineException>().having(
            (e) => e.message,
            'message',
            contains('audio part'),
          ),
        ),
      );
      expect(native.created('input_data'), 2);
      expect(native.deleted('input_data'), 2);
      expect(native.order, isNot(contains('compute_embedding')));
      expect(native.live.keys, unorderedEquals(['engine', 'options']));
      expect(allocator.live, 0);
    });
  });

  group('a pass loaded without audio', () {
    test('audio never reaches the engine, alone or combined (core refuses '
        'it first; reaching the pass is a host bug)', () async {
      native.visionSignatures = const [70, 140];
      final p = pass(declaredMedia: {EmbeddingModality.image});
      await p.load();
      for (final input in [
        EmbeddingInput.audio(_wav),
        EmbeddingInput(text: 'x', audio: _wav),
      ]) {
        await expectLater(
          p.embed(input, TaskType.none),
          throwsA(isA<EmbeddingEngineException>()),
        );
      }
      expect(native.order, isNot(contains('input_data_create')));
      expect(allocator.live, 0);
      await p.close();
    });
  });

  group('embeddingParts', () {
    test('a combined input: text with its prefix, then the images in order, '
        'then the audio — whatever order the arguments were given in', () {
      final first = Uint8List.fromList([1]);
      final second = Uint8List.fromList([2]);
      final clip = Uint8List.fromList([3]);
      final parts = embeddingParts(
        EmbeddingInput(audio: clip, images: [first, second], text: 'hi'),
        TaskType.retrievalQuery,
      );
      expect(
        [for (final part in parts) part.kind],
        [
          EmbeddingPartKind.text,
          EmbeddingPartKind.image,
          EmbeddingPartKind.image,
          EmbeddingPartKind.audio,
        ],
      );
      expect(
        utf8.decode(parts[0].bytes),
        '${TaskType.retrievalQuery.prefix}hi',
      );
      expect(
        [for (final part in parts.skip(1)) part.bytes],
        [first, second, clip],
      );
    });

    test('a text input is one text part: the task prefix, then the text', () {
      for (final taskType in TaskType.values) {
        final parts = embeddingParts(EmbeddingInput.text('héllo'), taskType);
        expect(parts, hasLength(1));
        expect(parts.single.kind, EmbeddingPartKind.text);
        expect(utf8.decode(parts.single.bytes), '${taskType.prefix}héllo');
      }
    });

    test('an image input is one image part with its bytes: no prefix', () {
      for (final taskType in TaskType.values) {
        final parts = embeddingParts(EmbeddingInput.image(_png), taskType);
        expect(parts, hasLength(1));
        expect(parts.single.kind, EmbeddingPartKind.image);
        expect(parts.single.bytes, _png);
      }
    });

    test('an audio input is one audio part with its bytes: no prefix', () {
      final clip = Uint8List.fromList([82, 73, 70, 70]);
      final parts = embeddingParts(
        EmbeddingInput.audio(clip),
        TaskType.retrievalQuery,
      );
      expect(parts.single.kind, EmbeddingPartKind.audio);
      expect(parts.single.bytes, clip);
    });
  });

  group('close', () {
    test('deletes the engine and options once; idempotent', () async {
      final p = pass();
      await p.load();
      await p.close();
      await p.close();
      expect(native.deleted('engine'), 1);
      expect(native.deleted('options'), 1);
      expectNothingLeaked();
    });

    test('is safe before load', () async {
      await pass().close();
      expect(native.order, isEmpty);
    });
  });

  group('the symbol gate (R5 §4.11)', () {
    test('a library without an EmbeddingEngine symbol is refused by name', () {
      expect(
        () => checkLiteRtLmEmbeddingSymbols(
          (symbol) => symbol != 'litert_lm_embedding_engine_create',
          library: 'libLiteRtLm.so',
        ),
        throwsA(
          isA<EmbeddingLoadException>()
              .having((e) => e.engine, 'engine', 'LiteRT-LM')
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('libLiteRtLm.so'),
                  contains('litert_lm_embedding_engine_create'),
                  contains('native-v0.18.0-e'),
                ),
              ),
        ),
      );
    });

    test('a complete library passes', () {
      checkLiteRtLmEmbeddingSymbols((_) => true, library: 'libLiteRtLm.so');
    });

    test('covers every native function the pass calls', () async {
      native.visionSignatures = const [70, 140];
      final p = pass(declaredMedia: {EmbeddingModality.image});
      await p.load();
      await p.embed(EmbeddingInput.text('x'), TaskType.retrievalQuery);
      await p.embed(EmbeddingInput.image(_png), TaskType.none);
      native.failCompute = (code: 3, message: 'bad image');
      await expectLater(
        p.embed(EmbeddingInput.image(_png), TaskType.none),
        throwsA(isA<EmbeddingEngineException>()),
      );
      await p.close();
      expect(
        native.symbolsCalled,
        containsAll([
          'litert_lm_embedding_response_get_input_length',
          'litert_lm_embedding_response_get_truncated_length',
        ]),
      );
      expect(
        native.symbolsCalled,
        contains(
          'litert_lm_embedding_engine_settings_set_vision_tokens_per_image',
        ),
      );
      expect(
        liteRtLmEmbeddingSymbols,
        containsAll(native.symbolsCalled),
        reason: 'the gate must check every symbol the pass looks up',
      );
    });
  });

  group('a per-SoC bundle on the NPU', () {
    setUp(() => native.textSignatures = _npuSignatures);

    test('settings on "npu", towers NULL, the dispatch directory handed to '
        'every executor, and a probe embedding before load returns', () async {
      native.visionSignatures = const [70, 140];
      final p = pass(
        npuTarget: _sm8850,
        declaredMedia: {EmbeddingModality.image},
      );
      final info = await p.load();
      expect(native.settingsBackend, 'npu');
      expect(native.towerBackendsNull, isTrue);
      expect(native.dispatchDirs, {
        'main': _dispatchDir,
        'vision': _dispatchDir,
        'audio': _dispatchDir,
      });
      // The dispatch directories are set before the engine exists.
      expect(
        native.order.indexOf('settings_set_litert_dispatch_lib_dir'),
        lessThan(native.order.indexOf('engine_create')),
      );
      // engine_create does not run the graph: the load embeds once itself.
      final probe = native.order.indexOf('compute_embedding');
      expect(probe, greaterThan(native.order.indexOf('options_create')));
      expect(native.lastTexts, ['task: search result | query: probe']);
      expect(native.created('response'), 1);
      expect(native.deleted('response'), 1);
      expect(info.dimension, 4);
      expect(info.maxInputTokens, 1024);
      expect(info.modalities, {
        EmbeddingModality.text,
        EmbeddingModality.image,
      });

      final vector = await p.embed(
        EmbeddingInput.text('hello'),
        TaskType.retrievalQuery,
      );
      expect(vector, hasLength(4));
      await p.close();
      expectNothingLeaked();
    });

    test(
      'the CPU path is unchanged: "cpu", no dispatch directory, no probe',
      () async {
        native.textSignatures = _allSignatures;
        final p = pass();
        await p.load();
        expect(native.settingsBackend, 'cpu');
        expect(native.dispatchDirs, isEmpty);
        expect(native.order, isNot(contains('compute_embedding')));
        await p.close();
        expectNothingLeaked();
      },
    );

    test('a probe the NPU cannot run fails the load, naming the SoC, and '
        'frees the engine', () async {
      // What macOS gives an SM8850 bundle: create succeeds, then the graph
      // cannot be prepared.
      native.failCompute = (
        code: 2,
        message: 'Failed to invoke the compiled model',
      );
      final p = pass(npuTarget: _sm8850);
      await expectLater(
        p.load(),
        throwsA(
          isA<EmbeddingLoadException>()
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('could not run $_file on the NPU'),
                  contains('Failed to invoke the compiled model'),
                  contains('compiled for Qualcomm SM8850'),
                ),
              )
              .having((e) => e.nativeCode, 'nativeCode', 2),
        ),
      );
      expect(native.deleted('engine'), 1);
      expect(native.deleted('options'), 1);
      await p.close();
      expectNothingLeaked();
    });

    for (final (name, vector) in [
      ('a NaN', [0.5, double.nan, 0.1, 0.2]),
      ('an all-zero vector', [0.0, 0.0, 0.0, 0.0]),
      ('an infinity', [0.5, double.infinity, 0.1, 0.2]),
    ]) {
      test('a probe that returns $name fails the load', () async {
        native.vectorOverride = vector;
        final p = pass(npuTarget: _sm8850);
        await expectLater(
          p.load(),
          throwsA(
            isA<EmbeddingLoadException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('Qualcomm SM8850 NPU returned'),
                contains('not used'),
              ),
            ),
          ),
        );
        await p.close();
        expectNothingLeaked();
      });
    }

    test('a probe of the wrong size fails the load', () async {
      native.responseSize = 3;
      final p = pass(npuTarget: _sm8850);
      await expectLater(
        p.load(),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            contains('3 values for dimension 4'),
          ),
        ),
      );
      await p.close();
      expectNothingLeaked();
    });

    test('an NPU engine create that fails names the NPU, not the cache '
        'directory, whatever the code', () async {
      native.failEngine = (code: 3, message: 'dispatch init failed');
      final p = pass(npuTarget: _sm8850);
      await expectLater(
        p.load(),
        throwsA(
          isA<EmbeddingLoadException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('on the Qualcomm SM8850 NPU'),
              contains('dispatch init failed'),
              isNot(contains('cache directory')),
            ),
          ),
        ),
      );
      expectNothingLeaked();
    });

    test('the symbol gate covers what an NPU load calls', () async {
      final p = pass(npuTarget: _sm8850);
      await p.load();
      await p.close();
      expect(liteRtLmEmbeddingSymbols, containsAll(native.symbolsCalled));
      for (final setter in [
        'litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir',
        'litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir',
        'litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir',
      ]) {
        expect(native.symbolsCalled, contains(setter));
      }
    });
  });

  test('the release gate checks exactly the symbols the pass needs', () {
    // native/litert_lm/check_embedding_exports.py refuses to publish a
    // tarball whose libLiteRtLm lacks one; it must ask for the same list.
    final script = File(
      'native/litert_lm/check_embedding_exports.py',
    ).readAsStringSync();
    final list = RegExp(
      r'REQUIRED = \[(.*?)\]',
      dotAll: true,
    ).firstMatch(script)!.group(1)!;
    final required = [
      for (final m in RegExp(r'"([a-z_]+)"').allMatches(list)) m.group(1)!,
    ];
    expect(required, liteRtLmEmbeddingSymbols);
  });

  test('the bindings do not bind what D23 rules out', () {
    final source = File(
      'lib/src/ffi/litert_lm_embedding_bindings.dart',
    ).readAsStringSync();
    for (final symbol in [
      'litert_lm_loaded_file_supports_input_modality',
      'litert_lm_loaded_file_max_vision_token_budget',
      'litert_lm_loaded_file_modality_supported_backends',
    ]) {
      expect(source, isNot(contains("'$symbol'")), reason: symbol);
    }
  });
}

// ── Fakes ───────────────────────────────────────────────────────────────────

Pointer<T> _noLookup<T extends NativeType>(String symbol) =>
    throw StateError('the pass called $symbol, which the fake does not model');

typedef _Failure = ({int code, String message});

/// LiteRT-LM's EmbeddingEngine C API, in Dart. Counts every create and delete
/// per kind of object, records what the pass handed it, and fails on demand.
///
/// The C error state is thread-local and survives until the next failure on
/// the thread; this fake is stricter: any native call made after a failure,
/// other than the two error getters, overwrites it — so a pass that reads the
/// error late gets the wrong one.
final class _FakeLiteRtLm extends LiteRtLmEmbeddingBindings {
  _FakeLiteRtLm() : super.fromLookup(_noLookup);

  LiteRtLmModelType modelType = LiteRtLmModelType.kLiteRtLmModelTypeEmbedding;
  int dimension = 4;
  List<int>? textSignatures = _allSignatures; // null = -1
  List<int>? visionSignatures; // null = -1, as on the 270m

  _Failure? failLoadedFile;
  _Failure? failSettings;
  _Failure? failEngine;
  _Failure? failCompute;
  bool failOptions = false;
  bool failInputData = false;

  /// Fail only the input_data_create call with this index (0-based).
  int? failInputDataAt;
  int _inputDataCalls = 0;

  /// What every response reports (section 14 getters): the whole input.
  int responseInputLength = 12;
  int responseTruncatedLength = 0;
  bool silentNullCompute = false;
  bool silentNullEngine = false;
  bool writeCacheOnCreate = true;
  _Failure? errorFromSetter;
  int? responseSize;

  /// When set, every response holds these values instead of the counting
  /// ones (a NaN, all zeros, …).
  List<double>? vectorOverride;

  /// The dispatch directory handed to each executor: main, vision, audio.
  final dispatchDirs = <String, String>{};

  final order = <String>[];
  final symbolsCalled = <String>{};
  final live = <String, Set<int>>{};
  final _created = <String, int>{};
  final _deleted = <String, int>{};

  String? loadedPath;
  String? settingsModelPath;
  String? settingsBackend;
  bool towerBackendsNull = false;
  String? cacheDir;
  int? maxInputLength;
  int? numThreads;
  bool? normalize;
  bool? insertSpecialTokens;
  LiteRtLmInputOverflowStrategy? overflowStrategy;
  int? visionTokensPerImage;
  final _inputs = <int, (LiteRtLmInputDataType, Uint8List)>{};
  List<String> lastTexts = const [];
  List<Uint8List> lastParts = const [];
  List<LiteRtLmInputDataType> lastPartTypes = const [];
  List<double> lastVector = const [];
  final _vectors = <int, Pointer<Float>>{};

  int _nextAddress = 0x10000;
  int _errorCode = 0;
  Pointer<Utf8> _errorMessage = nullptr;

  int created(String kind) => _created[kind] ?? 0;

  /// What a failure on this thread long before left behind.
  void setStaleError(int code, String message) => _setError(code, message);
  int deleted(String kind) => _deleted[kind] ?? 0;

  void dispose() {
    for (final values in _vectors.values) {
      calloc.free(values);
    }
    _vectors.clear();
    if (_errorMessage != nullptr) calloc.free(_errorMessage);
    _errorMessage = nullptr;
  }

  void _call(String name, String symbol) {
    order.add(name);
    symbolsCalled.add(symbol);
    if (_errorCode != 0) _setError(99, 'overwritten by $name');
  }

  void _setError(int code, String message) {
    if (_errorMessage != nullptr) calloc.free(_errorMessage);
    _errorCode = code;
    _errorMessage = message.toNativeUtf8();
  }

  Pointer<T> _create<T extends NativeType>(String kind) {
    final address = _nextAddress += 0x10;
    (live[kind] ??= {}).add(address);
    _created[kind] = created(kind) + 1;
    return Pointer.fromAddress(address);
  }

  void _delete(String kind, Pointer<NativeType> handle) {
    final set = live[kind];
    if (set == null || !set.remove(handle.address)) {
      throw StateError('$kind ${handle.address} deleted twice or never made');
    }
    if (set.isEmpty) live.remove(kind);
    _deleted[kind] = deleted(kind) + 1;
  }

  Pointer<T> _fail<T extends NativeType>(_Failure failure) {
    _setError(failure.code, failure.message);
    return nullptr;
  }

  static String _string(Pointer<Char> p) => p.cast<Utf8>().toDartString();

  // ── error reporter ──
  @override
  void litert_lm_clear_last_error() {
    order.add('clear_last_error');
    symbolsCalled.add('litert_lm_clear_last_error');
    if (_errorMessage != nullptr) calloc.free(_errorMessage);
    _errorMessage = nullptr;
    _errorCode = 0;
  }

  @override
  int litert_lm_get_last_error_code() {
    order.add('get_last_error_code');
    symbolsCalled.add('litert_lm_get_last_error_code');
    return _errorCode;
  }

  @override
  Pointer<Char> litert_lm_get_last_error_message() {
    order.add('get_last_error_message');
    symbolsCalled.add('litert_lm_get_last_error_message');
    return _errorMessage.cast();
  }

  // ── ModelInfo ──
  @override
  Pointer<LiteRtLmLoadedFile> litert_lm_loaded_file_create(
    Pointer<Char> litertlm_path,
  ) {
    _call('loaded_file_create', 'litert_lm_loaded_file_create');
    loadedPath = _string(litertlm_path);
    final failure = failLoadedFile;
    return failure != null ? _fail(failure) : _create('loaded_file');
  }

  @override
  void litert_lm_loaded_file_delete(Pointer<LiteRtLmLoadedFile> loaded_file) {
    _call('loaded_file_delete', 'litert_lm_loaded_file_delete');
    _delete('loaded_file', loaded_file);
  }

  @override
  LiteRtLmModelType litert_lm_loaded_file_model_type(
    Pointer<LiteRtLmLoadedFile> loaded_file,
  ) {
    _call('loaded_file_model_type', 'litert_lm_loaded_file_model_type');
    return modelType;
  }

  @override
  int litert_lm_loaded_file_embedding_dimension(
    Pointer<LiteRtLmLoadedFile> loaded_file,
  ) {
    _call(
      'loaded_file_embedding_dimension',
      'litert_lm_loaded_file_embedding_dimension',
    );
    return dimension;
  }

  int _list(List<int>? values, Pointer<Int32> lengths, int maxSize) {
    if (values == null) return -1;
    if (lengths != nullptr) {
      for (var i = 0; i < values.length && i < maxSize; i++) {
        lengths[i] = values[i];
      }
    }
    return values.length;
  }

  @override
  int litert_lm_loaded_file_embedding_signature_selection(
    Pointer<LiteRtLmLoadedFile> loaded_file,
    Pointer<Int32> lengths,
    int max_size,
  ) {
    _call(
      'loaded_file_embedding_signature_selection',
      'litert_lm_loaded_file_embedding_signature_selection',
    );
    return _list(textSignatures, lengths, max_size);
  }

  @override
  int litert_lm_loaded_file_vision_signature_selection(
    Pointer<LiteRtLmLoadedFile> loaded_file,
    Pointer<Int32> lengths,
    int max_size,
  ) {
    _call(
      'loaded_file_vision_signature_selection',
      'litert_lm_loaded_file_vision_signature_selection',
    );
    return _list(visionSignatures, lengths, max_size);
  }

  // ── settings ──
  @override
  Pointer<LiteRtLmEmbeddingEngineSettings>
  litert_lm_embedding_engine_settings_create(
    Pointer<Char> model_path,
    Pointer<Char> backend_str,
    Pointer<Char> vision_backend_str,
    Pointer<Char> audio_backend_str,
  ) {
    _call('settings_create', 'litert_lm_embedding_engine_settings_create');
    settingsModelPath = _string(model_path);
    settingsBackend = _string(backend_str);
    towerBackendsNull =
        vision_backend_str == nullptr && audio_backend_str == nullptr;
    final failure = failSettings;
    return failure != null ? _fail(failure) : _create('settings');
  }

  @override
  void litert_lm_embedding_engine_settings_delete(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
  ) {
    _call('settings_delete', 'litert_lm_embedding_engine_settings_delete');
    _delete('settings', settings);
  }

  @override
  void litert_lm_embedding_engine_settings_set_cache_dir(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    Pointer<Char> cache_dir,
  ) {
    _call(
      'settings_set_cache_dir',
      'litert_lm_embedding_engine_settings_set_cache_dir',
    );
    cacheDir = _string(cache_dir);
  }

  @override
  void litert_lm_embedding_engine_settings_set_max_input_length(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    int max_input_length,
  ) {
    _call(
      'settings_set_max_input_length',
      'litert_lm_embedding_engine_settings_set_max_input_length',
    );
    maxInputLength = max_input_length;
    final error = errorFromSetter;
    if (error != null) _setError(error.code, error.message);
  }

  @override
  void litert_lm_embedding_engine_settings_set_vision_tokens_per_image(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    int vision_tokens_per_image,
  ) {
    _call(
      'settings_set_vision_tokens_per_image',
      'litert_lm_embedding_engine_settings_set_vision_tokens_per_image',
    );
    visionTokensPerImage = vision_tokens_per_image;
  }

  @override
  void litert_lm_embedding_engine_settings_set_num_threads(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    int num_threads,
  ) {
    _call(
      'settings_set_num_threads',
      'litert_lm_embedding_engine_settings_set_num_threads',
    );
    numThreads = num_threads;
  }

  @override
  void litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    Pointer<Char> lib_dir,
  ) {
    _call(
      'settings_set_litert_dispatch_lib_dir',
      'litert_lm_embedding_engine_settings_set_litert_dispatch_lib_dir',
    );
    dispatchDirs['main'] = _string(lib_dir);
  }

  @override
  void litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    Pointer<Char> lib_dir,
  ) {
    _call(
      'settings_set_vision_litert_dispatch_lib_dir',
      'litert_lm_embedding_engine_settings_set_vision_litert_dispatch_lib_dir',
    );
    dispatchDirs['vision'] = _string(lib_dir);
  }

  @override
  void litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
    Pointer<Char> lib_dir,
  ) {
    _call(
      'settings_set_audio_litert_dispatch_lib_dir',
      'litert_lm_embedding_engine_settings_set_audio_litert_dispatch_lib_dir',
    );
    dispatchDirs['audio'] = _string(lib_dir);
  }

  // ── engine ──
  @override
  Pointer<LiteRtLmEmbeddingEngine> litert_lm_embedding_engine_create(
    Pointer<LiteRtLmEmbeddingEngineSettings> settings,
  ) {
    _call('engine_create', 'litert_lm_embedding_engine_create');
    final failure = failEngine;
    if (failure != null) return _fail(failure);
    if (silentNullEngine) return nullptr;
    final dir = cacheDir;
    if (writeCacheOnCreate && dir != null) {
      File('$dir/model.text_encoder.xnnpack_cache').writeAsStringSync('w');
    }
    return _create('engine');
  }

  @override
  void litert_lm_embedding_engine_delete(
    Pointer<LiteRtLmEmbeddingEngine> engine,
  ) {
    _call('engine_delete', 'litert_lm_embedding_engine_delete');
    _delete('engine', engine);
  }

  // ── options ──
  @override
  Pointer<LiteRtLmEmbeddingOptions> litert_lm_embedding_options_create() {
    _call('options_create', 'litert_lm_embedding_options_create');
    return failOptions ? nullptr : _create('options');
  }

  @override
  void litert_lm_embedding_options_delete(
    Pointer<LiteRtLmEmbeddingOptions> options,
  ) {
    _call('options_delete', 'litert_lm_embedding_options_delete');
    _delete('options', options);
  }

  @override
  void litert_lm_embedding_options_set_normalize(
    Pointer<LiteRtLmEmbeddingOptions> options,
    bool normalize,
  ) {
    _call('options_set_normalize', 'litert_lm_embedding_options_set_normalize');
    this.normalize = normalize;
  }

  @override
  void litert_lm_embedding_options_set_insert_special_tokens(
    Pointer<LiteRtLmEmbeddingOptions> options,
    bool insert_special_tokens,
  ) {
    _call(
      'options_set_insert_special_tokens',
      'litert_lm_embedding_options_set_insert_special_tokens',
    );
    insertSpecialTokens = insert_special_tokens;
  }

  @override
  void litert_lm_embedding_options_set_input_overflow_strategy(
    Pointer<LiteRtLmEmbeddingOptions> options,
    LiteRtLmInputOverflowStrategy strategy,
  ) {
    _call(
      'options_set_input_overflow_strategy',
      'litert_lm_embedding_options_set_input_overflow_strategy',
    );
    overflowStrategy = strategy;
  }

  // ── inputs, compute, response ──
  @override
  Pointer<LiteRtLmInputData> litert_lm_input_data_create(
    LiteRtLmInputDataType type,
    Pointer<Void> data,
    int size,
  ) {
    _call('input_data_create', 'litert_lm_input_data_create');
    if (failInputData) return nullptr; // sets no error, as upstream
    if (_inputDataCalls++ == failInputDataAt) return nullptr;
    // Copied, as upstream does: the pass frees its buffer right after.
    final bytes = Uint8List.fromList(data.cast<Uint8>().asTypedList(size));
    final handle = _create<LiteRtLmInputData>('input_data');
    _inputs[handle.address] = (type, bytes);
    return handle;
  }

  @override
  void litert_lm_input_data_delete(Pointer<LiteRtLmInputData> input_data) {
    _call('input_data_delete', 'litert_lm_input_data_delete');
    _delete('input_data', input_data);
    _inputs.remove(input_data.address);
  }

  @override
  Pointer<LiteRtLmEmbeddingResponse>
  litert_lm_embedding_engine_compute_embedding(
    Pointer<LiteRtLmEmbeddingEngine> engine,
    Pointer<Pointer<LiteRtLmInputData>> inputs,
    int num_inputs,
    Pointer<LiteRtLmEmbeddingOptions> options,
  ) {
    _call('compute_embedding', 'litert_lm_embedding_engine_compute_embedding');
    if (!(live['engine']?.contains(engine.address) ?? false)) {
      throw StateError('compute on a dead engine');
    }
    if (!(live['options']?.contains(options.address) ?? false)) {
      throw StateError('compute with dead options');
    }
    final parts = [
      for (var i = 0; i < num_inputs; i++) _inputs[inputs[i].address]!,
    ];
    lastPartTypes = [for (final (type, _) in parts) type];
    lastParts = [for (final (_, bytes) in parts) bytes];
    // A text part must be valid UTF-8: decoding throws otherwise.
    lastTexts = [
      for (final (type, bytes) in parts)
        if (type == LiteRtLmInputDataType.kLiteRtLmInputDataTypeText)
          utf8.decode(bytes),
    ];
    final failure = failCompute;
    if (failure != null) return _fail(failure);
    if (silentNullCompute) return nullptr;
    final response = _create<LiteRtLmEmbeddingResponse>('response');
    final n = responseSize ?? dimension;
    final values = calloc<Float>(n);
    final vector = <double>[];
    for (var i = 0; i < n; i++) {
      values[i] = vectorOverride?[i] ?? (i + 1) * 0.25 + lastParts.first.length;
      vector.add(values[i]);
    }
    lastVector = vector;
    _vectors[response.address] = values;
    return response;
  }

  @override
  int litert_lm_embedding_response_get_size(
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    _call('response_get_size', 'litert_lm_embedding_response_get_size');
    return responseSize ?? dimension;
  }

  @override
  int litert_lm_embedding_response_get_input_length(
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    _call(
      'response_get_input_length',
      'litert_lm_embedding_response_get_input_length',
    );
    return responseInputLength;
  }

  @override
  int litert_lm_embedding_response_get_truncated_length(
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    _call(
      'response_get_truncated_length',
      'litert_lm_embedding_response_get_truncated_length',
    );
    return responseTruncatedLength;
  }

  @override
  Pointer<Float> litert_lm_embedding_response_get_values(
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    _call('response_get_values', 'litert_lm_embedding_response_get_values');
    return _vectors[response.address]!;
  }

  @override
  void litert_lm_embedding_response_delete(
    Pointer<LiteRtLmEmbeddingResponse> response,
  ) {
    _call('response_delete', 'litert_lm_embedding_response_delete');
    _delete('response', response);
    final values = _vectors.remove(response.address);
    if (values != null) calloc.free(values);
  }
}

/// [calloc], counting what is still allocated.
final class _CountingAllocator implements Allocator {
  int live = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    live++;
    return calloc.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer<NativeType> pointer) {
    live--;
    calloc.free(pointer);
  }
}

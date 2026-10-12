import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/src/domain/platform_types.dart';
import 'package:flutter_edge_ai/src/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_edge_ai/src/registry/runtime_config.dart';
import 'package:flutter_edge_ai/src/interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Nothing but what a fake must implement, to pin what it gets for free.
final class _BareEmbedder extends EmbeddingModel {
  @override
  int get dimension => 1;
  @override
  bool get isClosed => false;
  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async => const [0.0];
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

void main() {
  ActiveEmbedderParams params({
    String model = '/m.tflite',
    String? tokenizer = '/t.json',
    PreferredBackend? backend,
  }) => ActiveEmbedderParams(
    modelPath: model,
    tokenizerPath: tokenizer,
    preferredBackend: backend,
  );

  group('ActiveEmbedderParams', () {
    test('gpu is NOT a difference — it builds the same model as cpu', () {
      // The whole point of normalizing gpu to CPU: asking for GPU must not
      // unload and reload a bit-identical embedder. If this goes red, the
      // normalization line was dropped and every backend change costs a
      // 570-780 ms recompile for nothing.
      expect(
        params(
          backend: PreferredBackend.gpu,
        ).firstDifference(params(backend: PreferredBackend.cpu)),
        isNull,
      );
      expect(
        params().firstDifference(params(backend: PreferredBackend.gpu)),
        isNull,
      );
    });

    test('npu IS a difference: an embedder cached for one side never serves '
        'the other', () {
      // An EmbeddingGemma 2 per-SoC bundle runs on the NPU, and its vectors
      // are not the CPU bundle's. If npu keyed as cpu, a cached CPU embedder
      // would answer an npu request (and an NPU one a request without npu)
      // without the backend ever being asked — a silent switch of vector
      // space.
      expect(
        params().firstDifference(params(backend: PreferredBackend.npu)),
        'activeBackend',
      );
      expect(
        params(
          backend: PreferredBackend.cpu,
        ).firstDifference(params(backend: PreferredBackend.npu)),
        'activeBackend',
      );
      expect(
        params(backend: PreferredBackend.npu).activeBackend,
        PreferredBackend.npu,
      );
      expect(
        params(backend: PreferredBackend.gpu).activeBackend,
        PreferredBackend.cpu,
      );
      expect(
        params(backend: PreferredBackend.npu).withMedia(const {}).activeBackend,
        PreferredBackend.npu,
        reason: 'a widened rebuild keeps the backend it was built for',
      );
    });

    test('paths are differences, and the changed one is named', () {
      expect(
        params().firstDifference(params(model: '/other.tflite')),
        'modelPath',
      );
      expect(
        params().firstDifference(params(tokenizer: '/other.json')),
        'tokenizerPath',
      );
      expect(
        params().firstDifference(params(tokenizer: null)),
        'tokenizerPath',
        reason:
            'losing the tokenizer is a different embedder, not a null-safe no-op',
      );
    });

    test('identical requests compare equal', () {
      expect(params().firstDifference(params()), isNull);
    });

    test('equal requests are ==, because the type says so now', () {
      // Without operator == the shells' "same embedder" question could be
      // answered by identity, which always says "different" and always
      // rebuilds. The house style for value types in this package implements it.
      expect(params(backend: PreferredBackend.gpu), params());
      expect(
        params(backend: PreferredBackend.gpu).hashCode,
        params().hashCode,
        reason: 'a normalised backend must not change the hash either',
      );
      expect(params(model: '/other.tflite'), isNot(params()));
    });

    test('an empty modelPath is rejected at construction', () {
      // modelPath IS the identity. RuntimeConfig documents '' as the web value,
      // so an adopter wiring config.modelPath straight in would make every
      // embedder compare equal to every other and silently reuse a stale one.
      // A throw, not an assert: an assert is stripped in release, which is the
      // build where that silent reuse would actually ship.
      expect(() => ActiveEmbedderParams(modelPath: ''), throwsArgumentError);
    });

    test(
      'isIgnoredBackend is true only for gpu, which no embedder runs on',
      () {
        expect(ActiveEmbedderParams.isIgnoredBackend(null), isFalse);
        expect(
          ActiveEmbedderParams.isIgnoredBackend(PreferredBackend.cpu),
          isFalse,
        );
        expect(
          ActiveEmbedderParams.isIgnoredBackend(PreferredBackend.gpu),
          isTrue,
        );
        expect(
          ActiveEmbedderParams.isIgnoredBackend(PreferredBackend.npu),
          isFalse,
          reason: 'an EmbeddingGemma 2 per-SoC bundle runs on it',
        );
      },
    );
  });

  group('noticeEmbedderBackendIgnored', () {
    late List<String> printed;
    late DebugPrintCallback original;

    setUp(() {
      resetEmbedderBackendNotice();
      printed = <String>[];
      original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) printed.add(message);
      };
    });

    tearDown(() {
      debugPrint = original;
      edgeAiLogLevel = EdgeAiLogLevel.info;
    });

    test('says nothing for the backend embeddings actually use', () {
      noticeEmbedderBackendIgnored(null);
      noticeEmbedderBackendIgnored(PreferredBackend.cpu);
      expect(printed, isEmpty);
    });

    test('names the requested backend, and points at the release channel', () {
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, hasLength(1));
      expect(printed.single, contains('gpu'));
      expect(
        printed.single,
        contains('activeBackend'),
        reason: 'a debug line must hand over to something a release build has',
      );
    });

    test('a muted log does not spend the one shot', () {
      // The level is public API, and an app that starts silent and raises it
      // to debug this is the whole reason the flag must not burn early.
      edgeAiLogLevel = EdgeAiLogLevel.none;
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, isEmpty);

      edgeAiLogLevel = EdgeAiLogLevel.info;
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, hasLength(1), reason: 'the shot was still unspent');
    });

    test('says it once, and a reset lets it speak again', () {
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, hasLength(1), reason: 'once per isolate, not per call');

      resetEmbedderBackendNotice();
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, hasLength(2));
      expect(printed.last, contains('gpu'));
    });

    test('npu is not called ignored before the backend has answered', () {
      noticeEmbedderBackendIgnored(PreferredBackend.npu);
      expect(
        printed,
        isEmpty,
        reason:
            'an NPU bundle runs on it; "Embeddings run on CPU" would be '
            'false for it',
      );
    });

    test('npu not applied: said when the built embedder is not on the NPU, '
        'silent when it is or when npu was not asked for', () {
      noticeEmbedderNpuNotApplied(PreferredBackend.npu, PreferredBackend.npu);
      noticeEmbedderNpuNotApplied(null, PreferredBackend.cpu);
      noticeEmbedderNpuNotApplied(PreferredBackend.gpu, PreferredBackend.cpu);
      expect(printed, isEmpty);

      noticeEmbedderNpuNotApplied(PreferredBackend.npu, PreferredBackend.cpu);
      expect(printed, hasLength(1));
      expect(printed.single, contains('npu is not applied'));
      expect(printed.single, contains('cpu'));
      expect(printed.single, contains('activeBackend'));

      noticeEmbedderNpuNotApplied(PreferredBackend.npu, PreferredBackend.cpu);
      expect(printed, hasLength(1), reason: 'the same one shot');
    });

    test('on web every requested backend is reported as not applied, cpu '
        'included, and none of them as CPU', () {
      // Web embeddings run where the runtime puts them — WebGPU first — so a
      // request for cpu is ignored too, and "run on CPU" would name a backend
      // that did not run.
      noticeWebEmbedderBackendIgnored(null);
      expect(printed, isEmpty, reason: 'nothing was asked for');

      noticeWebEmbedderBackendIgnored(PreferredBackend.cpu);
      expect(printed, hasLength(1));
      expect(printed.single, contains('cpu'));
      expect(printed.single, isNot(contains('CPU')));
      expect(printed.single, contains('activeBackend'));
    });

    test('the web and native lines share the one shot', () {
      noticeWebEmbedderBackendIgnored(PreferredBackend.gpu);
      noticeEmbedderBackendIgnored(PreferredBackend.gpu);
      expect(printed, hasLength(1));
    });
  });

  test(
    'the facade carries the engine\'s answer, it does not decide one',
    () async {
      // A descriptor claiming GPU must come back as GPU. If this goes red because
      // it answers `cpu`, the fact was moved back into the shared facade — and
      // then the next engine that really does use an accelerator is reported as
      // CPU with nothing to catch it.
      final model = await CommonEmbeddingModel.start(
        const EmbeddingPassDescriptor<String>(
          engineTag: 'fake',
          factory: _buildFakePass,
          config: 'fake',
          activeBackend: PreferredBackend.gpu,
        ),
        declaredMedia: const {},
        label: 'fake',
      );
      addTearDown(model.close);
      expect(model.activeBackend, PreferredBackend.gpu);
    },
  );

  test('EmbeddingModel.activeBackend defaults to null, not to a guess', () {
    // Defaulted rather than abstract, so a fake (the only subclass outside
    // core) need not answer it. Null means "not known here".
    expect(_BareEmbedder().activeBackend, isNull);
  });
}

/// Minimal pass: the facade must carry whatever the descriptor declares, so the
/// pass itself only has to be loadable.
final class _FakePass extends EmbeddingPass {
  @override
  Future<EmbeddingPassInfo> load() async =>
      const EmbeddingPassInfo(dimension: 2);
  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) async =>
      const [1.0, 0.0];
  @override
  Future<void> close() async {}
}

/// Top-level: the descriptor crosses into core's worker isolate.
EmbeddingPass _buildFakePass(String _) => _FakePass();

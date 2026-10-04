import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/core/domain/platform_types.dart';
import 'package:flutter_edge_ai/core/embedding/embedder_backend_notice.dart';
import 'package:flutter_edge_ai/core/utils/edge_ai_log.dart';
import 'package:flutter_edge_ai/core/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/core/embedding/forward_pass.dart';
import 'package:flutter_edge_ai/core/embedding/tokenizer_adapter.dart';
import 'package:flutter_edge_ai/core/registry/runtime_config.dart';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

/// Nothing but the defaults, to pin what an implementation gets for free.
class _BareEmbedder extends EmbeddingModel {
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [];
  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) async => const [];
  @override
  Future<int> getDimension() async => 0;
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
    test(
      'a different backend is NOT a difference — it builds the same model',
      () {
        // The whole point of normalizing to CPU: asking for GPU must not unload
        // and reload a bit-identical embedder. If this goes red, the
        // normalization line was dropped and every backend change costs a
        // 570-780 ms recompile for nothing.
        expect(
          params(
            backend: PreferredBackend.gpu,
          ).firstDifference(params(backend: PreferredBackend.cpu)),
          isNull,
        );
        expect(
          params().firstDifference(params(backend: PreferredBackend.npu)),
          isNull,
        );
      },
    );

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

    test('isIgnoredBackend is true only for something CPU is not', () {
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
        isTrue,
      );
    });
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
      noticeEmbedderBackendIgnored(PreferredBackend.npu);
      expect(printed, hasLength(1), reason: 'once per isolate, not per call');

      resetEmbedderBackendNotice();
      noticeEmbedderBackendIgnored(PreferredBackend.npu);
      expect(printed, hasLength(2));
      expect(printed.last, contains('npu'));
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
      final model = await CommonEmbeddingModel.create(
        descriptor: ForwardPassDescriptor(
          engineTag: 'fake',
          modelPath: 'fake',
          factory: buildFakePass,
          tokenizerFactory: buildFakeTokenizer,
          outputContract: EmbeddingOutputContract.pooledFinal,
          activeBackend: PreferredBackend.gpu,
        ),
        tokenizerPath: 'fake',
      );
      addTearDown(model.close);
      expect(model.activeBackend, PreferredBackend.gpu);
    },
  );

  test('a throwing close listener cannot cancel the teardown', () async {
    // `addCloseListener` is public, and `CloseNotifier` calls each listener
    // bare. Listeners therefore fire AFTER the worker teardown, so one throw
    // cannot exit `close()` before `_worker.close()` is sent — which is what
    // happened when this branch briefly fired them first, leaking the isolate
    // for good because `_isClosed` made the retry a no-op. The listener's
    // error still reaches the caller: silenced would be worse.
    var tornDown = false;
    final model = await CommonEmbeddingModel.create(
      descriptor: ForwardPassDescriptor(
        engineTag: 'fake',
        modelPath: 'fake',
        factory: buildFakePass,
        tokenizerFactory: buildFakeTokenizer,
        outputContract: EmbeddingOutputContract.pooledFinal,
        activeBackend: PreferredBackend.cpu,
      ),
      tokenizerPath: 'fake',
      onClose: () => tornDown = true,
    );
    model.addCloseListener(() => throw StateError('listener failed'));

    await expectLater(
      model.close(),
      throwsStateError,
      reason: "the listener's failure belongs to whoever closed the model",
    );
    expect(
      tornDown,
      isTrue,
      reason:
          'onClose runs after the worker teardown, so the teardown happened',
    );
    expect(model.isClosed, isTrue);
  });

  test('EmbeddingModel.activeBackend defaults to null, not to a guess', () {
    // Defaulted rather than abstract so an existing SUBCLASS keeps compiling.
    // `implements` does not inherit a default body, so those still break — this
    // PR's own genkit fake had to add the override. Null means "not known here".
    expect(_BareEmbedder().activeBackend, isNull);
  });
}

/// Minimal pass: the facade must carry whatever the descriptor declares, so the
/// pass itself only has to be loadable.
class _FakePass implements EmbeddingForwardPass {
  @override
  Future<void> load() async {}
  @override
  Future<void> close() async {}
  @override
  int get outputDimension => 2;
  @override
  int? get inputSequenceLength => null;
  @override
  EmbeddingOutputContract? get outputContract => null;
  @override
  Future<ForwardResult> run({
    required List<int> tokenIds,
    List<int>? attentionMask,
    List<int>? tokenTypeIds,
  }) async => const ForwardResult(values: [1.0, 0.0], shape: [1, 2]);
}

EmbeddingForwardPass buildFakePass(String modelPath) => _FakePass();

class _FakeTokenizer implements EmbeddingTokenizer {
  const _FakeTokenizer();
  @override
  TokenizedInput encode(String prefix, String text) =>
      const TokenizedInput(ids: [1, 2]);
}

Future<EmbeddingTokenizer> buildFakeTokenizer(String path) async =>
    const _FakeTokenizer();

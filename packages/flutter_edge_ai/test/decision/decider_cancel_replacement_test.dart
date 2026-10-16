// A decision that was cancelled, or whose decider was closed, while its
// embedding waited never asks core for a replacement embedder: on a model
// core built, that would load the model again — hundreds of MB, seconds of
// work — for an answer nobody wants. It fails with DeciderCancelledException.

import 'dart:async';

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_edge_ai/src/embedding/common_embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_host.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_pass.dart';
import 'package:flutter_test/flutter_test.dart';

import 'core_embedder_fixture.dart';

/// Serves [tableVectors]; while [hold] is set it parks every request, and a
/// close fails the parked ones with EmbedderClosedException — the request
/// never ran — as the real hosts do.
final class _HoldingHost implements EmbeddingHost {
  bool hold = false;
  int calls = 0;
  final _parked = <Completer<List<double>>>[];
  bool _closed = false;

  @override
  EmbeddingPassInfo get info => const EmbeddingPassInfo(dimension: 3);

  @override
  Set<EmbeddingModality> get modalities => const {EmbeddingModality.text};

  @override
  Future<List<double>> embed(EmbeddingInput input, TaskType taskType) {
    calls++;
    if (_closed) return Future.error(const EmbedderClosedException());
    if (!hold) return Future.value(tableVectors[input.text]!);
    final parked = Completer<List<double>>();
    _parked.add(parked);
    return parked.future;
  }

  @override
  Future<String> get unexpectedExit => Completer<String>().future;

  @override
  Future<void> close() async {
    _closed = true;
    for (final parked in _parked) {
      parked.completeError(const EmbedderClosedException());
    }
    _parked.clear();
  }
}

DeciderInput _in(String text) => DeciderInput(EmbeddingInput.text(text));

void main() {
  late _HoldingHost host;
  late CommonEmbeddingModel model;
  late int replacements;
  void Function()? onReplace;
  _HoldingHost? replacementHost;
  late Decider decider;

  CommonEmbeddingModel build(EmbeddingHost h) => CommonEmbeddingModel.withHost(
    h,
    activeBackend: PreferredBackend.cpu,
    installedFiles: const [(name: 'm.tflite', bytes: 1)],
    replacement: () async {
      replacements++;
      onReplace?.call();
      return build(replacementHost = _HoldingHost());
    },
  );

  setUp(() async {
    replacements = 0;
    onReplace = null;
    replacementHost = null;
    host = _HoldingHost();
    model = build(host);
    decider = await model.createDecider(
      options: [
        DeciderOption(
          'a',
          examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
        ),
        DeciderOption(
          'b',
          examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
        ),
      ],
      calibration: const EmbeddingDeciderCalibration.none(),
    );
    host.hold = true;
  });

  test(
    'a replaced embedder is still taken when nothing was cancelled',
    () async {
      final answer = decider.choose(_in('about a'));
      await pumpEventQueue();
      await model.close();
      expect((await answer).choice, 'a');
      expect(replacements, 1);
    },
  );

  test(
    'cancelled while the embedding waited: no replacement is loaded',
    () async {
      final token = CancelToken();
      final answer = decider.choose(_in('about a'), cancelToken: token);
      final failed = expectLater(
        answer,
        throwsA(isA<DeciderCancelledException>()),
      );
      await pumpEventQueue();
      token.cancel();
      await model.close();
      await failed;
      expect(replacements, 0);
    },
  );

  test('closed while the embedding waited: no replacement is loaded', () async {
    final answer = decider.choose(_in('about a'));
    final failed = expectLater(
      answer,
      throwsA(isA<DeciderCancelledException>()),
    );
    await pumpEventQueue();
    await decider.close();
    await model.close();
    await failed;
    expect(replacements, 0);
  });

  test('chooseAll, cancelled while its shared embedding waited: no '
      'replacement is loaded', () async {
    final token = CancelToken();
    final answers = Decider.chooseAll(_in('about a'), [
      decider,
    ], cancelToken: token);
    final failed = expectLater(
      answers,
      throwsA(isA<DeciderCancelledException>()),
    );
    await pumpEventQueue();
    token.cancel();
    await model.close();
    await failed;
    expect(replacements, 0);
  });

  test('an empty among on a closed embedder, cancelled while core replaced '
      'it: the answer is dropped', () async {
    final token = CancelToken();
    onReplace = token.cancel;
    await model.close();
    await expectLater(
      decider.choose(_in('about a'), among: const [], cancelToken: token),
      throwsA(isA<DeciderCancelledException>()),
    );
    expect(replacements, 1);
  });

  test('cancelled while core replaced the embedder: the answer is dropped, '
      'nothing is embedded on the replacement', () async {
    final token = CancelToken();
    onReplace = token.cancel;
    host.hold = false;
    await model.close();
    await expectLater(
      decider.choose(_in('about a'), cancelToken: token),
      throwsA(isA<DeciderCancelledException>()),
    );
    expect(replacements, 1);
    expect(replacementHost!.calls, 0);
  });

  test('closed while core replaced the embedder: nothing is embedded on the '
      'replacement', () async {
    onReplace = () => unawaited(decider.close());
    host.hold = false;
    await model.close();
    await expectLater(
      decider.choose(_in('about a')),
      throwsA(isA<DeciderCancelledException>()),
    );
    expect(replacements, 1);
    expect(replacementHost!.calls, 0);
  });

  test('chooseAll, another member of the group closed while the shared '
      'embedding waited: no replacement is loaded', () async {
    host.hold = false;
    final second = await model.createDecider(
      options: [
        DeciderOption(
          'a',
          examples: [EmbeddingInput.text('a1'), EmbeddingInput.text('a2')],
        ),
        DeciderOption(
          'b',
          examples: [EmbeddingInput.text('b1'), EmbeddingInput.text('b2')],
        ),
      ],
      calibration: const EmbeddingDeciderCalibration.none(),
    );
    host.hold = true;
    final answers = Decider.chooseAll(_in('about a'), [decider, second]);
    final failed = expectLater(
      answers,
      throwsA(isA<DeciderCancelledException>()),
    );
    await pumpEventQueue();
    await second.close();
    await model.close();
    await failed;
    expect(replacements, 0);
  });
}

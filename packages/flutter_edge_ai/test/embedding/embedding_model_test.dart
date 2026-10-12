// EmbeddingModel's defaulted members and its deprecated forwarders (R5 §2.1):
// what a test fake gets for free, and that the 2.1 methods are exactly the new
// ones under their old names.

// The forwarders are deprecated; calling them is what this file tests.
// ignore_for_file: deprecated_member_use_from_same_package

import 'dart:async';

import 'package:flutter_edge_ai/src/embedding/embedding_exceptions.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_input.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_modality.dart';
import 'package:flutter_edge_ai/src/embedding/embedding_model.dart';
import 'package:flutter_edge_ai/src/embedding/task_type.dart';
import 'package:flutter_edge_ai/src/lifecycle/close_notifier.dart';
import 'package:flutter_edge_ai/src/model_management/cancel_token.dart';
import 'package:flutter_test/flutter_test.dart';

/// The fake shape MIGRATION.md documents: only the abstract members.
final class _Fake extends EmbeddingModel with CloseNotifier {
  _Fake({this.gate});

  final Completer<void>? gate;
  final calls = <(EmbeddingInput, TaskType)>[];
  final returned = <List<double>>[];
  int inFlight = 0;
  int maxInFlight = 0;
  bool _closed = false;

  @override
  int get dimension => 3;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    calls.add((input, taskType));
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    try {
      if (gate != null) await gate!.future;
      final vector = [calls.length.toDouble(), 0.0, 0.0];
      returned.add(vector);
      return vector;
    } finally {
      inFlight--;
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    fireCloseListeners();
  }
}

void main() {
  group('defaults a fake inherits', () {
    test('text only, no declared limit, unknown backend', () {
      final model = _Fake();
      expect(model.modalities, {EmbeddingModality.text});
      expect(model.maxInputTokens, isNull);
      expect(model.activeBackend, isNull);
    });

    test('embedAll embeds one input at a time, in order', () async {
      final model = _Fake();
      final vectors = await model.embedAll([
        EmbeddingInput.text('a'),
        EmbeddingInput.text('b'),
        EmbeddingInput.text('c'),
      ], taskType: TaskType.clustering);

      expect(vectors, model.returned);
      expect(model.calls.map((c) => c.$1.text), ['a', 'b', 'c']);
      expect(model.calls.map((c) => c.$2).toSet(), {TaskType.clustering});
      expect(model.maxInFlight, 1);
    });

    test('embedAll stops before the next input once cancelled', () async {
      final gate = Completer<void>();
      final model = _Fake(gate: gate);
      final token = CancelToken();

      final all = model.embedAll(
        [EmbeddingInput.text('a'), EmbeddingInput.text('b')],
        taskType: TaskType.none,
        cancelToken: token,
      );
      await pumpEventQueue();
      token.cancel('test');
      gate.complete();

      await expectLater(all, throwsA(isA<EmbeddingCancelledException>()));
      expect(model.calls, hasLength(1));
    });
  });

  group('deprecated forwarders are the new API under the old names', () {
    test('generateEmbedding is embed(EmbeddingInput.text(t))', () async {
      final model = _Fake();
      final vector = await model.generateEmbedding(
        'hello',
        taskType: TaskType.retrievalDocument,
      );

      expect(identical(vector, model.returned.single), isTrue);
      final (input, taskType) = model.calls.single;
      expect(input.text, 'hello');
      expect(input.modalities, {EmbeddingModality.text});
      expect(taskType, TaskType.retrievalDocument);
    });

    test('generateEmbedding keeps its 2.1 default task', () async {
      final model = _Fake();
      await model.generateEmbedding('q');
      expect(model.calls.single.$2, TaskType.retrievalQuery);
    });

    test('generateEmbeddings is embedAll over text inputs', () async {
      final model = _Fake();
      final vectors = await model.generateEmbeddings(['x', 'y']);

      expect(vectors, hasLength(2));
      expect(identical(vectors[0], model.returned[0]), isTrue);
      expect(identical(vectors[1], model.returned[1]), isTrue);
      expect(model.calls.map((c) => c.$1.text), ['x', 'y']);
      expect(model.calls.map((c) => c.$2).toSet(), {TaskType.retrievalQuery});
    });

    test('getDimension is dimension', () async {
      expect(await _Fake().getDimension(), 3);
    });

    test('getDimension on a closed model fails as a future', () async {
      final model = _Fake();
      await model.close();

      late final Future<int> result;
      // Not thrown synchronously: the call itself must return.
      expect(() => result = model.getDimension(), returnsNormally);
      await expectLater(result, throwsA(isA<EmbedderClosedException>()));
    });
  });
}

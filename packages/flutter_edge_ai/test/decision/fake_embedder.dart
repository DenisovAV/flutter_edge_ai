// A deterministic EmbeddingModel for the decider tests: each text maps to a
// fixed vector, and every call is recorded.

import 'dart:async';

import 'package:flutter_edge_ai/engine.dart' show CloseNotifier;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';

final class FakeEmbedder extends EmbeddingModel with CloseNotifier {
  FakeEmbedder({
    required this.dimension,
    required this.table,
    this.activeBackend,
    Set<EmbeddingModality>? modalities,
  }) : modalities = modalities ?? const {EmbeddingModality.text};

  @override
  final int dimension;

  @override
  final PreferredBackend? activeBackend;

  @override
  final Set<EmbeddingModality> modalities;

  /// Text → vector. A text that is not in the table fails the request.
  final Map<String, List<double>> table;

  /// Every embed call, in order: the input's text and the task.
  final calls = <(String?, TaskType)>[];

  /// Thrown by the next embed, then cleared.
  Object? failNext;

  /// Runs at the start of every embed, before anything else.
  void Function(EmbeddingInput input)? onEmbed;

  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<List<double>> embed(
    EmbeddingInput input, {
    required TaskType taskType,
  }) async {
    onEmbed?.call(input);
    calls.add((input.text, taskType));
    if (_closed) throw const EmbedderClosedException();
    if (failNext case final error?) {
      failNext = null;
      throw error;
    }
    final vector = table[input.text];
    if (vector == null) {
      throw StateError('FakeEmbedder has no vector for "${input.text}"');
    }
    return List.of(vector);
  }

  @override
  Future<void> close() async {
    _closed = true;
    fireCloseListeners();
  }
}

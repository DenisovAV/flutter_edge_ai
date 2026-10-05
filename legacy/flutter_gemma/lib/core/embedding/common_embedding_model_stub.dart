// Web stub for `CommonEmbeddingModel`. The real implementation spawns a
// worker isolate, which dart2js/dart2wasm cannot compile, so the barrel
// selects this file under `if (dart.library.js_interop)`. Web engine arms
// build their own `EmbeddingModel` and never reach it at runtime; it exists
// only to keep the web compile honest.

import 'package:flutter_gemma/flutter_gemma_interface.dart'
    show EmbeddingModel, TaskType;
import 'package:flutter_gemma/core/lifecycle/close_notifier.dart';

import 'forward_pass.dart';

typedef VoidCallback = void Function();

class CommonEmbeddingModel extends EmbeddingModel with CloseNotifier {
  CommonEmbeddingModel._();

  static Future<CommonEmbeddingModel> create({
    required ForwardPassDescriptor descriptor,
    required String tokenizerPath,
    VoidCallback? onClose,
  }) async {
    throw UnsupportedError(
      'CommonEmbeddingModel is not available on web — use the web-specific '
      'embedding backend',
    );
  }

  @override
  Future<List<double>> generateEmbedding(
    String text, {
    TaskType taskType = TaskType.retrievalQuery,
  }) => throw UnsupportedError('stub');

  @override
  Future<List<List<double>>> generateEmbeddings(
    List<String> texts, {
    TaskType taskType = TaskType.retrievalQuery,
  }) => throw UnsupportedError('stub');

  @override
  Future<int> getDimension() => throw UnsupportedError('stub');

  @override
  Future<void> close() async {}
}

// The engine loads and answers in a plain Dart test run (`dart test`), which
// bundles libLiteRtLm through the build hook as `dart run` does.
//
// Run by hand: tool/test_all.sh does not discover this package (CI runs
// tool/plain_dart_check instead). The reply test needs a real model, and runs
// on the backend LITERTLM_BACKEND names (cpu, gpu or npu; cpu when unset):
//
//   LITERTLM_MODEL=/path/to/gemma-4-E2B-it.litertlm dart test
//   LITERTLM_MODEL=... LITERTLM_BACKEND=gpu dart test
import 'dart:io';

import 'package:litertlm_dart/litertlm_dart.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LITERTLM_MODEL'];
  final backendName = Platform.environment['LITERTLM_BACKEND'] ?? 'cpu';
  final backend = switch (backendName) {
    'cpu' => const Backend.cpu(),
    'gpu' => const Backend.gpu(),
    'npu' => Backend.npu(),
    _ => throw ArgumentError.value(backendName, 'LITERTLM_BACKEND'),
  };

  test(
    'an engine on $backend streams a reply',
    () async {
      final engine = await Engine.create(
        EngineConfig(modelPath: model!, backend: backend),
      );
      addTearDown(engine.close);
      final conversation = await engine.createConversation();
      addTearDown(conversation.close);
      final reply = StringBuffer();
      await for (final piece in conversation.sendMessageStream(
        Message.user('What is the capital of France? Answer in one word.'),
      )) {
        reply.write(piece.text);
      }
      expect('$reply', contains('Paris'));
    },
    tags: ['model'],
    timeout: const Timeout(Duration(minutes: 5)),
    skip: model == null ? 'set LITERTLM_MODEL to a .litertlm file' : false,
  );
}

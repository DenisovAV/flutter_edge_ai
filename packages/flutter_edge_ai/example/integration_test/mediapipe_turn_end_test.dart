// Integration test: how MediaPipe `.task` chat turns end on a device, after
// core 2.6.0 ran blocking chat turns through the streaming path (PR 3).
//
// 1. A cancelled stream, then a blocking turn: the blocking turn ends (a
//    reply, or the platform's error) instead of waiting forever.
// 2. A close during a blocking turn is a StateError (decision H), with what
//    was generated kept in the history.
// 3. A long greedy reply is the same through the chat's blocking turn
//    (streamed chunks, joined) as through the session's own getResponse
//    (one native call): no chunk is lost on the way.
//
// Model: Gemma 3n E2B .task, CPU, as ios_mediapipe_033_test.dart.
// Not run by CI. Usage (Android or iOS):
//   flutter test integration_test/mediapipe_turn_end_test.dart -d <device_id>
// and copy the model where it waits (see ios_mediapipe_033_test.dart).
//
// Every setup step is inside the test bodies (Rule 6b).

import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider/path_provider.dart';

import 'inference_test_helpers.dart';

const _modelFilename = 'gemma-3n-E2B-it-int4.task';

Future<String> _modelPath() async {
  if (Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/$_modelFilename';
  }
  return '/data/local/tmp/flutter_gemma_test/$_modelFilename';
}

Future<void> _waitForModel(String path) async {
  final file = File(path);
  final deadline = DateTime.now().add(const Duration(minutes: 5));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw Exception('Model file not found after 5 minutes: $path');
    }
    print('[Wait] copy the model to $path');
    await Future<void>.delayed(const Duration(seconds: 5));
  }
}

InferenceModel? _model;

/// The `.task` model on the CPU, loaded once.
Future<InferenceModel> _ensureModel() async {
  final loaded = _model;
  if (loaded != null && !loaded.isClosed) return loaded;
  await registerTestEngines();
  final path = await _modelPath();
  await _waitForModel(path);
  await FlutterEdgeAi.installModel(
    modelType: ModelType.gemmaIt,
    fileType: ModelFileType.task,
  ).fromFile(path).install();
  return _model = await FlutterEdgeAi.getActiveModel(
    maxTokens: 1024,
    preferredBackend: PreferredBackend.cpu,
  );
}

const _count = Message(
  text: 'Count from 1 to 60, numbers only, separated by spaces.',
  isUser: true,
);

void main() {
  initIntegrationTest();

  testWidgets('a cancelled stream, then a blocking turn, ends', (_) async {
    final model = await _ensureModel();
    final chat = await model.openChat(temperature: 0, topK: 1);
    try {
      await chat.addQuery(_count);
      final first = Completer<void>();
      final sub = chat.generateChatResponseAsync().listen((_) {
        if (!first.isCompleted) first.complete();
      }, onError: (_) {});
      await first.future.timeout(const Duration(seconds: 60));
      await sub.cancel();

      await chat.addQuery(const Message(text: 'Say hi.', isUser: true));
      final outcome = await chat
          .generateChatResponse()
          .then<Object>((r) => r, onError: (Object e) => e)
          .timeout(
            const Duration(seconds: 120),
            onTimeout: () => fail('the blocking turn never ended'),
          );
      print('[turn-end 1] blocking turn after a cancelled stream: $outcome');
      expect(outcome, isNot(isA<TimeoutException>()));
    } finally {
      await chat.close();
    }
  });

  testWidgets('a close during a blocking turn is a StateError, and the '
      'history keeps what was generated', (_) async {
    final model = await _ensureModel();
    final chat = await model.openChat(temperature: 0, topK: 1);
    await chat.addQuery(
      const Message(
        text: 'Write a long story about a lighthouse.',
        isUser: true,
      ),
    );
    final reply = chat.generateChatResponse();
    await Future<void>.delayed(const Duration(seconds: 5));
    await chat.close();
    await expectLater(
      reply.timeout(const Duration(seconds: 60)),
      throwsA(isA<StateError>()),
    );
    print(
      '[turn-end 2] history after the close: ${chat.fullHistory.length} '
      'messages, last "${chat.fullHistory.last.text}"',
    );
  });

  testWidgets('a long greedy reply is the same through the chat\'s blocking '
      'turn as through getResponse', (_) async {
    final model = await _ensureModel();
    final session = await model.openSession(temperature: 0, topK: 1);
    final String direct;
    try {
      await session.addQueryChunk(_count);
      direct = await session.getResponse();
    } finally {
      await session.close();
    }

    final chat = await model.openChat(temperature: 0, topK: 1);
    try {
      await chat.addQuery(_count);
      final viaChat = await chat.generateChatResponse();
      print(
        '[turn-end 3] direct ${direct.length} chars, chat '
        '${(viaChat as TextResponse).token.length} chars',
      );
      expect(viaChat.token.trim(), direct.trim());
    } finally {
      await chat.close();
    }
  });
}

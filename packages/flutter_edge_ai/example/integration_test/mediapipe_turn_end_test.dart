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

import 'package:flutter/services.dart' show PlatformException;
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

/// The two chat lanes: an open chat (multi-session) and the legacy
/// singleton chat, which run on different native paths.
final _lanes = <(String, Future<InferenceChat> Function(InferenceModel model))>[
  ('openChat', (m) => m.openChat(temperature: 0, topK: 1)),
  ('createChat', (m) => m.createChat(temperature: 0, topK: 1)),
];

/// A session on the same lane as the chat of [lane].
Future<InferenceModelSession> _sessionOn(String lane, InferenceModel model) =>
    lane == 'openChat'
    ? model.openSession(temperature: 0, topK: 1)
    : model.createSession(temperature: 0, topK: 1);

void main() {
  initIntegrationTest();

  for (final (lane, open) in _lanes) {
    testWidgets('$lane: a cancelled stream, then a blocking turn, ends', (
      _,
    ) async {
      final model = await _ensureModel();
      final chat = await open(model);
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
        print(
          '[turn-end $lane 1] blocking turn after a cancelled stream: '
          '$outcome',
        );
        // A reply, or the platform refusing while the detached generation
        // still runs; never a turn left waiting.
        expect(outcome, anyOf(isA<ModelResponse>(), isA<PlatformException>()));
      } finally {
        await chat.close();
      }
    });

    testWidgets('$lane: a close during a blocking turn is a StateError, and '
        'the history keeps what was generated', (_) async {
      final model = await _ensureModel();
      final chat = await open(model);
      await chat.addQuery(
        const Message(
          text: 'Write a long story about a lighthouse.',
          isUser: true,
        ),
      );
      final reply = chat.generateChatResponse();
      // Long enough for prefill and the first words on a phone's CPU.
      await Future<void>.delayed(const Duration(seconds: 10));
      await chat.close();
      await expectLater(
        reply.timeout(const Duration(seconds: 60)),
        throwsA(isA<StateError>()),
      );
      final last = chat.fullHistory.last;
      expect(last.isUser, isFalse, reason: 'the partial reply is kept');
      expect(last.text, isNotEmpty);
    });

    testWidgets('$lane: a long greedy reply is the same through the chat\'s '
        'blocking turn as through getResponse', (_) async {
      final model = await _ensureModel();
      final session = await _sessionOn(lane, model);
      final String direct;
      try {
        await session.addQueryChunk(_count);
        direct = await session.getResponse();
      } finally {
        await session.close();
      }

      final chat = await open(model);
      try {
        await chat.addQuery(_count);
        final viaChat = await chat.generateChatResponse();
        expect((viaChat as TextResponse).token.trim(), direct.trim());
        expect(chat.fullHistory.last.text, direct.trim());
      } finally {
        await chat.close();
      }
    });
  }
}

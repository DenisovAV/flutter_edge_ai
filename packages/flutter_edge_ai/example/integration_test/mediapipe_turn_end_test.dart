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
// 4. Rule A: a turn the chat takes back (stopped before any text, or failed
//    on an input longer than the context window) is taken out of the native
//    session too, which MediaPipe does by building the session again and
//    replaying the earlier turns. The turn after it recalls the earlier
//    history and not the taken-back message.
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

    testWidgets('$lane: a turn stopped before any text is taken out of the '
        'session; the next turn recalls the earlier one and not it', (_) async {
      final model = await _ensureModel();
      final chat = await open(model);
      try {
        await _tellName(chat);

        // Stopped before the first token: the long input keeps the model in
        // prefill while the stop lands.
        await chat.addQuery(
          Message(
            text:
                'My favourite colour is $_takenBackWord. ${_filler(150)} '
                'Repeat my favourite colour.',
            isUser: true,
          ),
        );
        final shown = <String>[];
        final sub = chat.generateChatResponseAsync().listen((r) {
          if (r is TextResponse) shown.add(r.token);
        }, onError: (_) {});
        await chat.stopGeneration();
        await sub.asFuture<void>().timeout(const Duration(seconds: 60));
        if (shown.join().trim().isNotEmpty) {
          markTestSkipped(
            '[turn-end $lane 4] text arrived before the stop landed '
            '("${shown.join()}"): not a zero-text stop on this device',
          );
          return;
        }
        expect(
          chat.fullHistory.any((m) => m.text.contains(_takenBackWord)),
          isFalse,
          reason: 'the chat took the turn back',
        );

        await _expectRecall(chat, lane, 'after a stop');
      } finally {
        await chat.close();
      }
    });

    testWidgets('$lane: a turn that fails on an input too long for the '
        'context is taken out of the session; the next turn recalls the '
        'earlier one and not it', (_) async {
      final model = await _ensureModel();
      final chat = await open(model);
      try {
        await _tellName(chat);

        // Several times the 1024-token context: MediaPipe refuses it.
        await chat.addQuery(
          Message(
            text: 'My favourite colour is $_takenBackWord. ${_filler(1500)}',
            isUser: true,
          ),
        );
        Object? failure;
        try {
          await chat.generateChatResponse().timeout(
            const Duration(seconds: 120),
          );
        } catch (e) {
          failure = e;
        }
        print('[turn-end $lane 5] the over-long turn ended with: $failure');
        if (failure == null) {
          markTestSkipped(
            '[turn-end $lane 5] the engine answered an input past its '
            'context window: no failure to take back on this device',
          );
          return;
        }
        expect(
          chat.fullHistory.any((m) => m.text.contains(_takenBackWord)),
          isFalse,
          reason: 'the chat took the failed turn back',
        );

        await _expectRecall(chat, lane, 'after a failure');
      } finally {
        await chat.close();
      }
    });
  }
}

/// A word no reply would contain unless the model saw the taken-back turn.
const _takenBackWord = 'vermilion';

/// [words] words of filler.
String _filler(int words) => List.filled(words, 'lighthouse').join(' ');

/// The turn the taken-back one follows: a fact the rebuilt session must keep.
Future<void> _tellName(InferenceChat chat) async {
  await chat.addQuery(
    const Message(
      text: 'My name is Ada. Reply with the single word OK.',
      isUser: true,
    ),
  );
  await chat.generateChatResponse().timeout(const Duration(seconds: 120));
}

/// A turn on the session as it is now: it must know the name, and must not
/// know the taken-back colour.
Future<void> _expectRecall(InferenceChat chat, String lane, String what) async {
  await chat.addQuery(
    const Message(
      text:
          'What is my name, and what is my favourite colour? If you were not '
          'told one, say unknown.',
      isUser: true,
    ),
  );
  final reply = await chat.generateChatResponse().timeout(
    const Duration(seconds: 120),
  );
  final text = (reply as TextResponse).token.toLowerCase();
  print('[turn-end $lane] recall $what: "$text"');
  expect(text, contains('ada'), reason: 'the earlier turn was replayed');
  expect(
    text,
    isNot(contains(_takenBackWord)),
    reason: 'the taken-back message is not in the session',
  );
}

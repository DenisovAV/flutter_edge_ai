// A stopped turn is rewound in place (flutter_edge_ai_litertlm
// `patch_c_api.sh` section 16): the next turn runs on the same conversation,
// which keeps every earlier turn — images and audio included — and the
// stopped exchange itself. Before it, the conversation was rebuilt from a
// text-only history and forgot earlier media.
//
// Covers both ways to stop: stopGeneration(), and cancelling the response
// subscription (awaited or not) with the next message sent right away — the
// path that once left a chat answering nothing (#682 review).
//
// Needs a libLiteRtLm with section 16: a local prebuilt from `build_macos.sh`
// (`build_ios.sh` on iOS) until a native release carries it. Gemma 4 E2B:
// macOS in the example's container Documents (see litertlm_ffi_test.dart);
// iOS via `--dart-define=IOS_TEST_DOCS_DIR=<host dir>` on the simulator or the
// app's Documents on a device; Android in /data/local/tmp/flutter_gemma_test.
//
// Run, one backend at a time:
//   flutter test integration_test/litertlm_stop_rewind_test.dart -d <device>
//   flutter test integration_test/litertlm_stop_rewind_test.dart -d <device> \
//     --dart-define=REWIND_BACKEND=gpu
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _backendName = String.fromEnvironment(
  'REWIND_BACKEND',
  defaultValue: 'cpu',
);
const _modelFile = 'gemma-4-E2B-it.litertlm';

Future<String> _modelPath() async {
  final home = Platform.environment['HOME'];
  String? path;
  if (Platform.isMacOS) {
    path =
        '$home/Library/Containers/dev.flutterberlin.flutterGemmaExample55/'
        'Data/Documents/$_modelFile';
  } else if (Platform.isLinux) {
    path = '$home/models/$_modelFile';
  } else if (Platform.isWindows) {
    path = '${Platform.environment['USERPROFILE']}\\models\\$_modelFile';
  } else if (Platform.isIOS &&
      const String.fromEnvironment('IOS_TEST_DOCS_DIR').isNotEmpty) {
    path = '${const String.fromEnvironment('IOS_TEST_DOCS_DIR')}/$_modelFile';
  } else {
    path = await stagedModelPath(_modelFile);
  }
  if (path == null || !File(path).existsSync()) {
    throw StateError('$_modelFile is not staged for this platform ($path)');
  }
  return path;
}

/// The plugin's own log lines, to tell a rewind from a rebuild.
final _log = <String>[];

class _Turn {
  _Turn(this.reply, this.error);
  final String reply;
  final Object? error;
}

/// Sends [message] and returns the reply; with [stop], stops the turn with
/// stopGeneration() at its first chunk, thought or text — or, with
/// [stopAfterText], after that many text chunks.
Future<_Turn> _send(
  InferenceChat chat,
  Message message,
  String label, {
  bool stop = false,
  int? stopAfterText,
}) async {
  await chat.addQueryChunk(message);
  final out = StringBuffer();
  Object? error;
  final sw = Stopwatch()..start();
  var textChunks = 0;
  try {
    await for (final r in chat.generateChatResponseAsync()) {
      if (r is TextResponse) {
        out.write(r.token);
        textChunks++;
      }
      final due = stopAfterText != null
          ? textChunks == stopAfterText && r is TextResponse
          : stop && (r is TextResponse || r is ThinkingResponse);
      if (due) {
        await chat.stopGeneration();
        stop = false;
      }
    }
  } catch (e) {
    error = e;
  }
  debugPrint(
    '[rewind/$_backendName] $label (${sw.elapsedMilliseconds} ms) '
    'error=${error?.toString().split('\n').first} '
    'reply=${out.toString().replaceAll('\n', ' ')}',
  );
  return _Turn(out.toString(), error);
}

/// Starts [message] and cancels its subscription — no stopGeneration() — at
/// its first text chunk, or after [after]. With [awaitCancel] false the cancel
/// is not awaited, so the caller's next message starts while it winds down.
Future<void> _abandon(
  InferenceChat chat,
  Message message,
  String label, {
  Duration? after,
  bool awaitCancel = true,
}) async {
  await chat.addQueryChunk(message);
  final first = Completer<void>();
  final sub = chat.generateChatResponseAsync().listen(
    (r) {
      if (r is TextResponse && !first.isCompleted) first.complete();
    },
    onError: (Object _) {
      if (!first.isCompleted) first.complete();
    },
    onDone: () {
      if (!first.isCompleted) first.complete();
    },
  );
  if (after != null) {
    await Future<void>.delayed(after);
  } else {
    await first.future;
  }
  final sw = Stopwatch()..start();
  final cancel = sub.cancel();
  if (awaitCancel) await cancel;
  debugPrint(
    '[rewind/$_backendName] $label abandoned '
    '(cancel ${awaitCancel ? 'took ${sw.elapsedMilliseconds} ms' : 'not awaited'})',
  );
}

Future<Uint8List> _asset(String path) async =>
    (await rootBundle.load(path)).buffer.asUint8List();

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final backend = PreferredBackend.values.byName(_backendName);
  InferenceModel? model;

  Future<InferenceModel> ensureModel() async {
    if (model != null) return model!;
    await registerTestEngines();
    await FlutterEdgeAi.installModel(
      modelType: ModelType.gemma4,
      fileType: ModelFileType.litertlm,
    ).fromFile(await _modelPath()).install();
    return model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: backend,
      supportImage: true,
      supportAudio: true,
    );
  }

  // Greedy: Gemma 4's own sampler makes a reply vary from run to run (a turn
  // that sometimes does not hear its own audio), and a probe must test the
  // rewind, not the sampler.
  Future<InferenceChat> newChat({bool thinking = false}) async =>
      (await ensureModel()).createChat(
        topK: 1,
        supportImage: true,
        supportAudio: true,
        enableThinking: thinking,
        // A thinking turn spends most of its tokens on thoughts.
        maxOutputTokens: thinking ? 1024 : 160,
      );

  final printer = debugPrint;
  setUpAll(() {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('[FfiInferenceModel]')) {
        _log.add(message);
      }
      printer(message, wrapWidth: wrapWidth);
    };
  });
  tearDownAll(() async {
    debugPrint = printer;
    await model?.close();
  });

  /// Every one of [stops] stops was recovered by a rewind, none by a rebuild.
  void expectRewoundOnly(int stops) {
    final rewound = _log.where((l) => l.contains('rewound the conversation'));
    final rebuilt = _log.where((l) => l.contains('rebuilt the conversation'));
    final kept = _log.where((l) => l.contains('ended natively before'));
    expect(rebuilt, isEmpty, reason: 'a stop fell back to a rebuild');
    expect(kept, isEmpty, reason: 'a stop was taken for a finished turn');
    expect(rewound, hasLength(stops));
    _log.clear();
  }

  const name = Message(
    text: 'My name is Zorblax. Greet me in five words.',
    isUser: true,
  );
  const story = Message(
    text: 'Write a long story about the sea, at least ten paragraphs.',
    isUser: true,
  );
  const askName = Message(
    text: 'What is my name? Answer with the name only.',
    isUser: true,
  );
  const hello = Message(text: 'Say hello.', isUser: true);

  testWidgets('text: the turn after a stop remembers earlier turns and the '
      'stopped one', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(chat, name, 'T1 name');
      // The colour is only in the stopped message: the model knows it only
      // if the stopped turn was put back.
      await _send(
        chat,
        const Message(
          text:
              'Write a long story about the sea, at least ten paragraphs. By '
              'the way, my favourite colour is purple.',
          isUser: true,
        ),
        'T2 stopped',
        stop: true,
      );
      final colour = await _send(
        chat,
        const Message(
          text: 'What is my favourite colour? Answer in one word.',
          isUser: true,
        ),
        'T3 colour',
      );
      final recalled = await _send(chat, askName, 'T4 name');

      expect(colour.error, isNull);
      expect(colour.reply.toLowerCase(), contains('purple'));
      expect(recalled.error, isNull);
      expect(recalled.reply.toLowerCase(), contains('zorblax'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('an image from an earlier turn survives a stop', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(
        chat,
        Message.withImage(
          text: 'Look at this picture. Reply with OK only.',
          imageBytes: await _asset('assets/eg2_vision/circle.png'),
          isUser: true,
        ),
        'T1 image',
      );
      await _send(chat, story, 'T2 stopped', stop: true);
      final shape = await _send(
        chat,
        const Message(
          text:
              'What shape is in the picture I showed you? Answer in one word.',
          isUser: true,
        ),
        'T3 shape',
      );

      expect(shape.error, isNull);
      expect(shape.reply.toLowerCase(), contains('circle'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('a stopped turn that carried the image keeps it', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(
        chat,
        Message.withImage(
          text: 'Describe this picture in great detail.',
          imageBytes: await _asset('assets/eg2_vision/circle.png'),
          isUser: true,
        ),
        'T1 image, stopped',
        stop: true,
      );
      final shape = await _send(
        chat,
        const Message(
          text: 'What shape was in that picture? Answer in one word.',
          isUser: true,
        ),
        'T2 shape',
      );

      expect(shape.error, isNull);
      expect(shape.reply.toLowerCase(), contains('circle'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('audio from an earlier turn survives a stop', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(
        chat,
        Message.withAudio(
          text: 'Listen to this. Reply with OK only.',
          audioBytes: await _asset('assets/eg2_audio/weather_paris.wav'),
          isUser: true,
        ),
        'T1 audio',
      );
      await _send(chat, story, 'T2 stopped', stop: true);
      final city = await _send(
        chat,
        const Message(
          text: 'Which city was mentioned in the audio? Answer with the city.',
          isUser: true,
        ),
        'T3 city',
      );

      expect(city.error, isNull);
      expect(city.reply.toLowerCase(), contains('paris'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  // Stopped a few words in, before the reply names the city, so the answer has
  // to come from the audio. On Metal the model names it. On CPU, Gemma 4 E2B
  // (greedy) answers from its own cut reply instead and says it has no audio:
  // measured with the same rewind and the same audio, the reply put back
  // decided it — "OK" gave "Paris", "The recording asks what the" (with or
  // without "…" or "(interrupted)") gave "please provide the audio". So on CPU
  // this checks the rewind and that the chat answers, not the city.
  testWidgets('a stopped turn that carried audio keeps it (a barge-in)', (
    tester,
  ) async {
    _log.clear();
    final chat = await newChat();
    try {
      final stopped = await _send(
        chat,
        Message.withAudio(
          text: 'Summarize what is said in this recording, in one sentence.',
          audioBytes: await _asset('assets/eg2_audio/weather_paris.wav'),
          isUser: true,
        ),
        'T1 audio, stopped',
        stopAfterText: 4,
      );
      expect(
        stopped.reply.toLowerCase(),
        isNot(contains('paris')),
        reason: 'the stopped reply must not already hold the answer',
      );
      final city = await _send(
        chat,
        const Message(
          text: 'Which city was mentioned in the audio? Answer with the city.',
          isUser: true,
        ),
        'T2 city',
      );

      expect(city.error, isNull);
      if (backend == PreferredBackend.cpu) {
        expect(city.reply.trim(), isNotEmpty);
      } else {
        expect(city.reply.toLowerCase(), contains('paris'));
      }
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('thinking: after a stop the conversation keeps answering '
      '(#681 review, critical 2)', (tester) async {
    _log.clear();
    final chat = await newChat(thinking: true);
    try {
      await _send(
        chat,
        Message.withImage(
          text: 'Describe this picture in one sentence.',
          imageBytes: await _asset('assets/eg2_vision/circle.png'),
          isUser: true,
        ),
        'T1 image',
      );
      await _send(chat, story, 'T2 stopped', stop: true);
      final turns = <_Turn>[
        await _send(
          chat,
          const Message(
            text: 'What shape is in the picture? Answer in one word.',
            isUser: true,
          ),
          'T3 shape',
        ),
        await _send(
          chat,
          const Message(
            text: 'What colour is it? Answer in one word.',
            isUser: true,
          ),
          'T4 colour',
        ),
        await _send(chat, hello, 'T5 hello'),
      ];

      for (final turn in turns) {
        expect(turn.error, isNull);
        expect(turn.reply.trim(), isNotEmpty);
      }
      expect(turns.first.reply.toLowerCase(), contains('circle'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('a failed image turn, then a stop: the name is still recalled '
      '(#681 review, critical 1)', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      final bad = await _send(
        chat,
        Message.withImage(
          text: 'What is this?',
          imageBytes: Uint8List.fromList([0, 1, 2, 3]),
          isUser: true,
        ),
        'T1 bad image',
      );
      await _send(chat, name, 'T2 name');
      await _send(chat, story, 'T3 stopped', stop: true);
      final first = await _send(chat, askName, 'T4 name');
      final second = await _send(chat, askName, 'T5 name');

      expect(bad.error, isNotNull, reason: 'four bytes are not an image');
      for (final turn in [first, second]) {
        expect(turn.error, isNull);
        expect(turn.reply.toLowerCase(), contains('zorblax'));
      }
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });

  testWidgets('a stopped first turn, and two stops in a row', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(
        chat,
        const Message(
          text: 'My name is Zorblax. Then tell me a long story about the sea.',
          isUser: true,
        ),
        'T1 stopped',
        stop: true,
      );
      await _send(
        chat,
        const Message(
          text: 'Tell me a long story about a forest.',
          isUser: true,
        ),
        'T2 stopped',
        stop: true,
      );
      final recalled = await _send(chat, askName, 'T3 name');

      expect(recalled.error, isNull);
      expect(recalled.reply.toLowerCase(), contains('zorblax'));
      expectRewoundOnly(2);
    } finally {
      await chat.close();
    }
  });

  for (final awaitCancel in [true, false]) {
    final how = awaitCancel ? 'awaited' : 'not awaited';
    testWidgets('a subscription cancelled ($how) at the first chunk, then the '
        'next message at once: the chat keeps answering', (tester) async {
      for (var i = 0; i < 5; i++) {
        _log.clear();
        final chat = await newChat();
        try {
          await _send(chat, name, '#$i T1 name');
          await _abandon(chat, story, '#$i T2', awaitCancel: awaitCancel);
          final recalled = await _send(chat, askName, '#$i T3 name');
          final greeted = await _send(chat, hello, '#$i T4 hello');

          expect(recalled.error, isNull);
          expect(recalled.reply.toLowerCase(), contains('zorblax'));
          expect(greeted.reply.trim(), isNotEmpty);
          expectRewoundOnly(1);
        } finally {
          await chat.close();
        }
      }
    });
  }

  testWidgets('a subscription cancelled during an image prefill, then the next '
      'message at once: the chat keeps answering', (tester) async {
    final image = await _asset('assets/eg2_vision/circle.png');
    for (var i = 0; i < 3; i++) {
      _log.clear();
      final chat = await newChat();
      try {
        await _send(chat, name, '#$i T1 name');
        await _abandon(
          chat,
          Message.withImage(
            text: 'Describe this picture in great detail.',
            imageBytes: image,
            isUser: true,
          ),
          '#$i T2 image',
          after: const Duration(milliseconds: 200),
        );
        final recalled = await _send(chat, askName, '#$i T3 name');

        expect(recalled.error, isNull);
        expect(recalled.reply.toLowerCase(), contains('zorblax'));
        expectRewoundOnly(1);
      } finally {
        await chat.close();
      }
    }
  });

  testWidgets('an image survives a cancelled subscription: a rewind, not a '
      'rebuild', (tester) async {
    _log.clear();
    final chat = await newChat();
    try {
      await _send(
        chat,
        Message.withImage(
          text: 'Look at this picture. Reply with OK only.',
          imageBytes: await _asset('assets/eg2_vision/circle.png'),
          isUser: true,
        ),
        'T1 image',
      );
      await _abandon(chat, story, 'T2', awaitCancel: false);
      final shape = await _send(
        chat,
        const Message(
          text:
              'What shape is in the picture I showed you? Answer in one word.',
          isUser: true,
        ),
        'T3 shape',
      );

      expect(shape.error, isNull);
      expect(shape.reply.toLowerCase(), contains('circle'));
      expectRewoundOnly(1);
    } finally {
      await chat.close();
    }
  });
}

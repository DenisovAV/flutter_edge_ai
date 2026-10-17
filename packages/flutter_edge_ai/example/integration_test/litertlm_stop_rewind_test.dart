// A stopped turn is rewound in place (flutter_edge_ai_litertlm
// `patch_c_api.sh` section 15): the next turn runs on the same conversation,
// which keeps every earlier turn — images and audio included — and the
// stopped exchange itself. Before it, the conversation was rebuilt from a
// text-only history and forgot earlier media.
//
// Needs a libLiteRtLm with section 15: a local prebuilt from `build_macos.sh`
// until a native release carries it. Gemma 4 E2B, in the example's container
// Documents on macOS (see litertlm_ffi_test.dart).
//
// Run, one backend at a time:
//   flutter test integration_test/litertlm_stop_rewind_test.dart -d macos
//   flutter test integration_test/litertlm_stop_rewind_test.dart -d macos \
//     --dart-define=REWIND_BACKEND=gpu
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/flutter_edge_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;

const _backendName = String.fromEnvironment(
  'REWIND_BACKEND',
  defaultValue: 'cpu',
);

String get _modelPath {
  final home = Platform.environment['HOME'];
  if (Platform.isMacOS) {
    return '$home/Library/Containers/dev.flutterberlin.flutterGemmaExample55/'
        'Data/Documents/gemma-4-E2B-it.litertlm';
  }
  if (Platform.isAndroid) {
    return '/data/local/tmp/flutter_gemma_test/gemma-4-E2B-it.litertlm';
  }
  if (Platform.isLinux) return '$home/models/gemma-4-E2B-it.litertlm';
  if (Platform.isWindows) {
    return '${Platform.environment['USERPROFILE']}\\models\\'
        'gemma-4-E2B-it.litertlm';
  }
  throw UnsupportedError('No local model path on this platform');
}

/// What the plugin logged during a test, to tell a rewind from a rebuild.
final _log = <String>[];

class _Turn {
  _Turn(this.reply, this.error);
  final String reply;
  final Object? error;
}

/// Sends [message] and returns the reply; with [stop], stops the turn at its
/// first chunk, thought or text.
Future<_Turn> _send(
  InferenceChat chat,
  Message message,
  String label, {
  bool stop = false,
}) async {
  await chat.addQueryChunk(message);
  final out = StringBuffer();
  Object? error;
  final sw = Stopwatch()..start();
  try {
    await for (final r in chat.generateChatResponseAsync()) {
      if (r is TextResponse) out.write(r.token);
      if (stop && (r is TextResponse || r is ThinkingResponse)) {
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
    ).fromFile(_modelPath).install();
    return model = await FlutterEdgeAi.getActiveModel(
      maxTokens: 4096,
      preferredBackend: backend,
      supportImage: true,
      supportAudio: true,
    );
  }

  Future<InferenceChat> newChat({bool thinking = false}) async =>
      (await ensureModel()).createChat(
        supportImage: true,
        supportAudio: true,
        enableThinking: thinking,
        // A thinking turn spends most of its tokens on thoughts.
        maxOutputTokens: thinking ? 1024 : 160,
      );

  final printer = debugPrint;
  setUpAll(() {
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) _log.add(message);
      printer(message, wrapWidth: wrapWidth);
    };
  });
  tearDownAll(() async {
    debugPrint = printer;
    await model?.close();
  });

  /// Every stop in the test was recovered by a rewind, none by a rebuild.
  void expectRewoundOnly(int stops) {
    final rewound = _log.where((l) => l.contains('rewound the conversation'));
    final rebuilt = _log.where((l) => l.contains('rebuilt the conversation'));
    expect(rebuilt, isEmpty, reason: 'a stop fell back to a rebuild');
    expect(rewound, hasLength(stops));
    _log.clear();
  }

  testWidgets('text: the turn after a stop remembers earlier turns and the '
      'stopped one', (tester) async {
    _log.clear();
    final chat = await newChat();
    await _send(
      chat,
      const Message(
        text: 'My name is Zorblax. Greet me in five words.',
        isUser: true,
      ),
      'T1 name',
    );
    // The colour is only in the stopped message: the model knows it only if
    // the stopped turn was put back.
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
    final name = await _send(
      chat,
      const Message(
        text: 'What is my name? Answer with the name only.',
        isUser: true,
      ),
      'T4 name',
    );
    await chat.close();

    expect(colour.error, isNull);
    expect(colour.reply.toLowerCase(), contains('purple'));
    expect(name.error, isNull);
    expect(name.reply.toLowerCase(), contains('zorblax'));
    expectRewoundOnly(1);
  });

  testWidgets('an image from an earlier turn survives a stop', (tester) async {
    _log.clear();
    final chat = await newChat();
    await _send(
      chat,
      Message.withImage(
        text: 'Look at this picture. Reply with OK only.',
        imageBytes: await _asset('assets/eg2_vision/circle.png'),
        isUser: true,
      ),
      'T1 image',
    );
    await _send(
      chat,
      const Message(text: 'Tell me a long story about the sea.', isUser: true),
      'T2 stopped',
      stop: true,
    );
    final shape = await _send(
      chat,
      const Message(
        text: 'What shape is in the picture I showed you? Answer in one word.',
        isUser: true,
      ),
      'T3 shape',
    );
    await chat.close();

    expect(shape.error, isNull);
    expect(shape.reply.toLowerCase(), contains('circle'));
    expectRewoundOnly(1);
  });

  testWidgets('a stopped turn that carried the image keeps it', (tester) async {
    _log.clear();
    final chat = await newChat();
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
    await chat.close();

    expect(shape.error, isNull);
    expect(shape.reply.toLowerCase(), contains('circle'));
    expectRewoundOnly(1);
  });

  testWidgets('audio from an earlier turn survives a stop', (tester) async {
    _log.clear();
    final chat = await newChat();
    await _send(
      chat,
      Message.withAudio(
        text: 'Listen to this. Reply with OK only.',
        audioBytes: await _asset('assets/eg2_audio/weather_paris.wav'),
        isUser: true,
      ),
      'T1 audio',
    );
    await _send(
      chat,
      const Message(text: 'Tell me a long story about the sea.', isUser: true),
      'T2 stopped',
      stop: true,
    );
    final city = await _send(
      chat,
      const Message(
        text: 'Which city was mentioned in the audio? Answer with the city.',
        isUser: true,
      ),
      'T3 city',
    );
    await chat.close();

    expect(city.error, isNull);
    expect(city.reply.toLowerCase(), contains('paris'));
    expectRewoundOnly(1);
  });

  testWidgets('thinking: after a stop the conversation keeps answering '
      '(#681 review, critical 2)', (tester) async {
    _log.clear();
    final chat = await newChat(thinking: true);
    await _send(
      chat,
      Message.withImage(
        text: 'Describe this picture in one sentence.',
        imageBytes: await _asset('assets/eg2_vision/circle.png'),
        isUser: true,
      ),
      'T1 image',
    );
    await _send(
      chat,
      const Message(text: 'Tell me a long story about the sea.', isUser: true),
      'T2 stopped',
      stop: true,
    );
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
      await _send(
        chat,
        const Message(text: 'Say hello.', isUser: true),
        'T5 hello',
      ),
    ];
    await chat.close();

    for (final turn in turns) {
      expect(turn.error, isNull);
      expect(turn.reply.trim(), isNotEmpty);
    }
    expect(turns.first.reply.toLowerCase(), contains('circle'));
    expectRewoundOnly(1);
  });

  testWidgets('a failed image turn, then a stop: the name is still recalled '
      '(#681 review, critical 1)', (tester) async {
    _log.clear();
    final chat = await newChat();
    final bad = await _send(
      chat,
      Message.withImage(
        text: 'What is this?',
        imageBytes: Uint8List.fromList([0, 1, 2, 3]),
        isUser: true,
      ),
      'T1 bad image',
    );
    await _send(
      chat,
      const Message(
        text: 'My name is Zorblax. Reply with OK only.',
        isUser: true,
      ),
      'T2 name',
    );
    await _send(
      chat,
      const Message(text: 'Tell me a long story about the sea.', isUser: true),
      'T3 stopped',
      stop: true,
    );
    final first = await _send(
      chat,
      const Message(
        text: 'What is my name? Answer with the name only.',
        isUser: true,
      ),
      'T4 name',
    );
    final second = await _send(
      chat,
      const Message(
        text: 'What is my name? Answer with the name only.',
        isUser: true,
      ),
      'T5 name',
    );
    await chat.close();

    expect(bad.error, isNotNull, reason: 'four bytes are not an image');
    for (final turn in [first, second]) {
      expect(turn.error, isNull);
      expect(turn.reply.toLowerCase(), contains('zorblax'));
    }
    expectRewoundOnly(1);
  });

  testWidgets('a stopped first turn, and two stops in a row', (tester) async {
    _log.clear();
    final chat = await newChat();
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
      const Message(text: 'Tell me a long story about a forest.', isUser: true),
      'T2 stopped',
      stop: true,
    );
    final name = await _send(
      chat,
      const Message(
        text: 'What is my name? Answer with the name only.',
        isUser: true,
      ),
      'T3 name',
    );
    await chat.close();

    expect(name.error, isNull);
    expect(name.reply.toLowerCase(), contains('zorblax'));
    expectRewoundOnly(2);
  });
}

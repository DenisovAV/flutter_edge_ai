// FFI openSession sessions as native conversations (core 2.6.0 design §1.1,
// L3): on a backend where several live conversations were verified, each
// open session holds its own LiteRT-LM conversation, takes images, is rewound
// after a stop (§16) or a full context (§23), and costs memory while idle.
//
// What it checks, through the Dart engine:
// - the backing the load chose (native where verified; set
//   OPEN_EXPECT_BACKING=virtual on a backend that is not);
// - three sessions interleaved, each recalling only its own code word;
// - an image in one session, a turn on another, the image recalled;
// - a stop in one session, a turn on another, the stopped session recalls
//   its earlier turns (rewound on CPU/GPU, rebuilt from text on the NPU or a
//   model with linear attention state);
// - a full context: an input longer than the window and one longer than the
//   room left both end with TurnEnd.contextLimit, the session then answers
//   again with its history intact; once no prefill fits, every turn ends
//   contextLimit and nothing is dropped;
// - the memory one idle open session adds, and RSS and switch time over
//   OPEN_SWITCHES switches (printed as RESULT lines).
//
// Models: macOS in the example's container Documents (see
// litertlm_ffi_test.dart), Linux ~/models, Windows %USERPROFILE%\models,
// Android /data/local/tmp/flutter_gemma_test.
//
// Run, one backend at a time:
//   flutter test integration_test/litertlm_open_sessions_test.dart -d macos \
//     --dart-define=OPEN_BACKEND=gpu
// Optional: OPEN_MODEL (file name, default gemma-4-E2B-it.litertlm),
// OPEN_MODEL_TYPE (a ModelType name, default gemma4), OPEN_MAX_TOKENS (4096),
// OPEN_MEDIA (true: the model takes images), OPEN_SWITCHES (100).
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_diagnostics/flutter_edge_ai_diagnostics.dart';
// ignore: implementation_imports — the open-session backing the load chose
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
// ignore: implementation_imports — the open-session backing the load chose
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'inference_test_helpers.dart' show registerTestEngines;
import 'voice_test_helpers.dart' show stagedModelPath;

const _backendName = String.fromEnvironment(
  'OPEN_BACKEND',
  defaultValue: 'cpu',
);
const _modelFile = String.fromEnvironment(
  'OPEN_MODEL',
  defaultValue: 'gemma-4-E2B-it.litertlm',
);
const _modelTypeName = String.fromEnvironment(
  'OPEN_MODEL_TYPE',
  defaultValue: 'gemma4',
);
const _maxTokens = int.fromEnvironment('OPEN_MAX_TOKENS', defaultValue: 4096);
const _media = bool.fromEnvironment('OPEN_MEDIA', defaultValue: true);
const _switches = int.fromEnvironment('OPEN_SWITCHES', defaultValue: 100);
const _expectBacking = String.fromEnvironment(
  'OPEN_EXPECT_BACKING',
  defaultValue: 'native',
);

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

void _result(String line) =>
    debugPrint('RESULT open_sessions/$_backendName $line');

Future<String> _ask(InferenceModelSession s, String text) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  final reply = await s.getResponse();
  debugPrint(
    '[open/$_backendName] "$text" -> "${reply.replaceAll('\n', ' ')}"',
  );
  return reply;
}

/// One turn through the engine's own turn API, as core's chat runs it: the
/// text, and how the turn ended.
Future<(String, TurnEnd)> _turn(InferenceModelSession s, String text) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  // ignore: invalid_use_of_protected_member
  final turn = s.startTurn();
  final reply = await turn.text.join();
  final end = await turn.end!;
  debugPrint(
    '[open/$_backendName] turn of ${text.length} chars -> $end '
    '"${reply.length > 60 ? '${reply.substring(0, 60)}…' : reply}"',
  );
  return (reply, end);
}

Future<int> _anonymousBytes() async {
  final bytes =
      (await FlutterEdgeAiDiagnostics.memorySnapshot()).anonymousBytes;
  if (bytes == null) throw StateError('anonymousBytes is not reported here');
  return bytes;
}

String _mib(num bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final backend = PreferredBackend.values.byName(_backendName);
  FfiInferenceModel? model;

  Future<FfiInferenceModel> ensureModel() async {
    if (model != null) return model!;
    await registerTestEngines();
    await FlutterEdgeAi.installModel(
      modelType: ModelType.values.byName(_modelTypeName),
      fileType: ModelFileType.litertlm,
    ).fromFile(await _modelPath()).install();
    final loaded = await FlutterEdgeAi.getActiveModel(
      maxTokens: _maxTokens,
      preferredBackend: backend,
      supportImage: _media,
    );
    return model = loaded as FfiInferenceModel;
  }

  Future<InferenceModelSession> open() =>
      ensureModel().then((m) => m.openSession(topK: 1));

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

  testWidgets('the load chose the expected backing', (tester) async {
    final m = await ensureModel();
    _result(
      'backing=${m.openSessionBacking.name} active=${m.activeBackend?.name} '
      'noRewind=${m.noRewindReason} maxTokens=${m.maxTokens}',
    );
    expect(m.openSessionBacking.name, _expectBacking);
  });

  testWidgets('three interleaved sessions each recall only their own word', (
    tester,
  ) async {
    final words = ['PELICAN', 'TURNIP', 'GRANITE'];
    final sessions = [for (final _ in words) await open()];
    try {
      for (var i = 0; i < words.length; i++) {
        await _ask(
          sessions[i],
          'Remember this code word: ${words[i]}. Reply with OK only.',
        );
      }
      var passed = 0;
      for (var i = words.length - 1; i >= 0; i--) {
        final reply = (await _ask(
          sessions[i],
          'What is the code word? Answer with the word only.',
        )).toUpperCase();
        final own = reply.contains(words[i]);
        final foreign = [
          for (var j = 0; j < words.length; j++)
            if (j != i && reply.contains(words[j])) words[j],
        ];
        if (own && foreign.isEmpty) passed++;
      }
      _result('multiconv=$passed/${words.length}');
      expect(passed, words.length);
    } finally {
      for (final s in sessions) {
        await s.close();
      }
    }
  });

  testWidgets('an image stays in its session across a turn on another', (
    tester,
  ) async {
    if (!_media) {
      _result('media=not run (OPEN_MEDIA=false)');
      return;
    }
    final a = await open();
    final b = await open();
    try {
      final image = (await rootBundle.load(
        'assets/eg2_vision/circle.png',
      )).buffer.asUint8List();
      await a.addQueryChunk(
        Message.withImage(
          text: 'Look at this picture. Reply with OK only.',
          imageBytes: image,
          isUser: true,
        ),
      );
      await a.getResponse();
      await _ask(b, 'Name a fruit. One word.');
      final shape = (await _ask(
        a,
        'What shape is in the picture I showed you? Answer in one word.',
      )).toLowerCase();
      _result('media=${shape.contains('circle') ? 'PASS' : 'FAIL'}');
      expect(shape, contains('circle'));
    } finally {
      await a.close();
      await b.close();
    }
  });

  testWidgets('a stop in one session, a turn on another, and the stopped '
      'session still recalls its turns', (tester) async {
    _log.clear();
    final a = await open();
    final b = await open();
    try {
      await _ask(a, 'My name is Zorblax. Greet me in five words.');
      await a.addQueryChunk(
        const Message(
          text:
              'Write a long story about the sea, at least ten paragraphs. By '
              'the way, my favourite colour is purple.',
          isUser: true,
        ),
      );
      var chunks = 0;
      await for (final _ in a.getResponseAsync()) {
        if (++chunks == 1) await a.stopGeneration();
      }
      await _ask(b, 'Name a colour of the sky. One word.');
      final colour = (await _ask(
        a,
        'What is my favourite colour? One word.',
      )).toLowerCase();
      final name = (await _ask(
        a,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      final rewound = _log.where((l) => l.contains('rewound the conversation'));
      final rebuilt = _log.where((l) => l.contains('rebuilt the conversation'));
      final ended = _log.where((l) => l.contains('ended natively before'));
      expect(
        ended,
        isEmpty,
        reason: 'the stop must reach a running turn to test its recovery',
      );
      _result(
        'stoprewind colour=${colour.contains('purple')} '
        'name=${name.contains('zorblax')} rewound=${rewound.length} '
        'rebuilt=${rebuilt.length}',
      );
      expect(name, contains('zorblax'));
      expect(colour, contains('purple'));
      final m = await ensureModel();
      if (m.openSessionBacking == OpenSessionBacking.native) {
        if (m.noRewindReason == null) {
          expect(rewound, hasLength(1));
          expect(rebuilt, isEmpty);
        } else {
          expect(rebuilt, hasLength(1));
        }
      }
    } finally {
      await a.close();
      await b.close();
    }
  });

  testWidgets('a full context ends contextLimit, the session answers again, '
      'and nothing of its history is dropped', (tester) async {
    final m = await ensureModel();
    final s = await open();
    try {
      await _ask(s, 'My name is Zorblax. Reply with OK only.');
      // Longer than the whole window.
      final tooLong = List.filled(m.maxTokens + 200, 'lorem').join(' ');
      final (_, endTooLong) = await _turn(s, 'Summarise: $tooLong');
      expect(endTooLong, TurnEnd.contextLimit);
      final name1 = (await _ask(
        s,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      expect(name1, contains('zorblax'), reason: 'history kept after a rewind');

      // Fill the window a chunk at a time until a turn ends contextLimit.
      final chunk = List.filled(300, 'blue').join(' ');
      TurnEnd? end;
      var turns = 0;
      while (turns < 40) {
        turns++;
        (_, end) = await _turn(s, 'Reply with OK only. $chunk');
        if (end == TurnEnd.contextLimit) break;
      }
      expect(end, TurnEnd.contextLimit, reason: 'the window never filled');
      // Then smaller inputs, until even those do not fit: what is left is
      // then below the bundle's smallest prefill signature.
      final small = List.filled(40, 'blue').join(' ');
      for (var i = 0; i < 80; i++) {
        turns++;
        (_, end) = await _turn(s, 'Reply with OK only. $small');
        if (end == TurnEnd.contextLimit) break;
      }
      // A short input: it fits the window unless no prefill signature does.
      final (shortReply, shortEnd) = await _turn(s, 'What is my name?');
      _result(
        'contextfull tooLong=$endTooLong recalled=${name1.contains('zorblax')} '
        'filledAfter=$turns short=$shortEnd',
      );
      if (shortEnd == TurnEnd.contextLimit) {
        // No room left for any prefill: every later turn ends the same way,
        // and the session is not truncated behind the app's back.
        final (_, again) = await _turn(s, 'Hi');
        expect(again, TurnEnd.contextLimit);
      } else {
        expect(shortReply.toLowerCase(), contains('zorblax'));
      }
    } finally {
      await s.close();
    }
  });

  testWidgets('measures the memory one idle open session adds, and drift over '
      'switches (RESULT lines, no assertion)', (tester) async {
    if (!FlutterEdgeAiDiagnostics.isSupported) {
      _result('memory=not supported here');
      return;
    }
    final m = await ensureModel();
    // A first session, so the engine's own buffers are allocated before the
    // baseline.
    final first = await open();
    await _ask(first, 'Reply with OK only.');
    final base = await _anonymousBytes();
    const extra = 4;
    final idle = <InferenceModelSession>[];
    final deltas = <int>[];
    var previous = base;
    try {
      for (var i = 0; i < extra; i++) {
        final s = await open();
        idle.add(s);
        await _ask(s, 'Reply with OK only.');
        // A turn on the first session switches the new one out: its KV is
        // saved as an idle snapshot.
        await _ask(first, 'Reply with OK only.');
        final now = await _anonymousBytes();
        deltas.add(now - previous);
        previous = now;
      }
      final perSession = (previous - base) / extra;
      _result(
        'idle_session_mib=${_mib(perSession)} maxTokens=${m.maxTokens} '
        'deltas_mib=${deltas.map(_mib).join(',')}',
      );

      // Switch drift: alternate two sessions.
      final a = first;
      final b = idle.first;
      final before = await _anonymousBytes();
      final sw = Stopwatch()..start();
      for (var i = 0; i < _switches; i++) {
        await _ask(i.isEven ? a : b, 'Reply with OK only.');
        if ((i + 1) % 50 == 0) {
          debugPrint(
            '[open] after ${i + 1} switches: '
            '${_mib(await _anonymousBytes() - before)} MiB',
          );
        }
      }
      final perTurnMs = sw.elapsedMilliseconds / _switches;
      final after = await _anonymousBytes();
      _result(
        'switches=$_switches turn_ms=${perTurnMs.toStringAsFixed(0)} '
        'drift_mib=${_mib(after - before)}',
      );
    } finally {
      for (final s in idle) {
        await s.close();
      }
      await first.close();
    }
  });
}

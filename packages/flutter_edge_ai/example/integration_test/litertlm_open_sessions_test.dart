// FFI openSession sessions as native conversations (core 2.6.0 design §1.1,
// L3): on a backend where several live conversations were verified, each
// open session holds its own LiteRT-LM conversation, takes images, is rewound
// after a stop (§16) or a full context (§23), and costs memory while idle.
//
// What it checks, through the Dart engine:
// - the backing the load chose (native where verified; set
//   OPEN_EXPECT_BACKING=virtual on a backend that is not: its full multimodal
//   history is replayed when sessions switch);
// - three sessions interleaved, each recalling only its own code word;
// - an image in one session, a turn on another, the image recalled;
// - a stop in one session, a turn on another, the stopped session recalls
//   its earlier turns (rewound on CPU/GPU, rebuilt from full messages on the
//   NPU or a model with linear attention state);
// - an audio clip in one session, a turn on another, the clip recalled;
// - a full context: an input longer than the window is refused with
//   ContextLimitException; a short input near the boundary may instead fit
//   and produce partial text before decode fills the window (both end
//   TurnEnd.contextLimit); the session then answers again with its history
//   intact; once no prefill fits, every turn is refused and nothing is
//   dropped; in openChat and createChat the refused message is taken back
//   out of the history;
// - measured, printed as RESULT lines: the memory one idle open session adds
//   (anonymous and file-backed bytes, and the GPU memory the device reports),
//   how long the native send call holds the calling isolate on a switch, and
//   memory and turn time over OPEN_SWITCHES switches.
//
// Models: macOS in ~/models with the example's container Documents as a
// fallback, Linux ~/models, Windows %USERPROFILE%\models, Android
// /data/local/tmp/flutter_gemma_test.
//
// Run, one backend at a time:
//   flutter test integration_test/litertlm_open_sessions_test.dart -d macos \
//     --dart-define=OPEN_BACKEND=gpu
// Optional: OPEN_MODEL (file name, default gemma-4-E2B-it.litertlm),
// OPEN_MODEL_TYPE (a ModelType name, default gemma4), OPEN_MAX_TOKENS (4096),
// OPEN_MEDIA / OPEN_AUDIO (true: the model takes images / audio),
// OPEN_SWITCHES (100).
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
import 'voice_test_helpers.dart' show macosStagedModelPath, stagedModelPath;

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
const _audio = bool.fromEnvironment('OPEN_AUDIO', defaultValue: true);
const _switches = int.fromEnvironment('OPEN_SWITCHES', defaultValue: 100);
const _expectBacking = String.fromEnvironment(
  'OPEN_EXPECT_BACKING',
  defaultValue: 'native',
);

Future<String> _modelPath() async {
  final home = Platform.environment['HOME'];
  String? path;
  if (Platform.isMacOS) {
    path = macosStagedModelPath(_modelFile);
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
/// text, how it ended, and the error it failed with, if any.
Future<(String, TurnEnd, Object?)> _turn(
  InferenceModelSession s,
  String text,
) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  // ignore: invalid_use_of_protected_member
  final turn = s.startTurn();
  final reply = StringBuffer();
  Object? error;
  try {
    await turn.text.forEach(reply.write);
  } catch (e) {
    error = e;
  }
  final end = await turn.end!;
  debugPrint(
    '[open/$_backendName] turn of ${text.length} chars -> $end '
    '${error == null ? '' : '(${error.runtimeType}) '}'
    '"${reply.length > 60 ? '${'$reply'.substring(0, 60)}…' : reply}"',
  );
  return ('$reply', end, error);
}

int _median(List<int> xs) => (List.of(xs)..sort())[xs.length ~/ 2];

String _mib(num bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

/// Content-bearing word stems used to compare an audio recall with the
/// transcription that this same session produced. Four-character stems let
/// "wash", "washboard", and "wash water" agree without accepting a generic
/// no-audio answer.
Set<String> _audioContentStems(String text) {
  const ignored = {
    'about',
    'audio',
    'clip',
    'from',
    'have',
    'hear',
    'recording',
    'repeat',
    'said',
    'that',
    'this',
    'transcription',
    'what',
    'with',
    'your',
  };
  return {
    for (final match in RegExp(r"[a-z0-9']+").allMatches(text.toLowerCase()))
      if (match[0] case final word?
          when word.length >= 4 && !ignored.contains(word))
        word.substring(0, 4),
  };
}

const _audioFixtureStems = {'dark', 'suit', 'grea', 'wash', 'wate', 'year'};
const _audioRecallQuestion =
    'Repeat the first six words of your transcription.';

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
      supportAudio: _audio,
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

  /// Images and audio are kept across a turn on another session, by native
  /// conversation state or by a virtual session's full-message replay.
  Future<void> mediaCheck({
    required String label,
    required Message Function() message,
    required String question,
    required bool Function(String initialReply, String recall) retained,
    required String expectation,
    Future<void> Function(InferenceModelSession other)? verifyIsolation,
  }) async {
    await ensureModel();
    final a = await open();
    final b = await open();
    try {
      await a.addQueryChunk(message());
      final initialReply = await a.getResponse();
      await _ask(b, 'Name a fruit. One word.');
      final reply = await _ask(a, question);
      final hit = retained(initialReply, reply);
      _result('$label=${hit ? 'PASS' : 'FAIL'}');
      expect(
        hit,
        isTrue,
        reason: '$expectation; initial="$initialReply", recall="$reply"',
      );
      await verifyIsolation?.call(b);
    } finally {
      await a.close();
      await b.close();
    }
  }

  testWidgets('an image stays in its session across a turn on another', (
    tester,
  ) async {
    if (!_media) {
      _result('image=not run (OPEN_MEDIA=false)');
      return;
    }
    final image = (await rootBundle.load(
      'assets/eg2_vision/circle.png',
    )).buffer.asUint8List();
    await mediaCheck(
      label: 'image',
      message: () => Message.withImage(
        text: 'Look at this picture. Reply with OK only.',
        imageBytes: image,
        isUser: true,
      ),
      question:
          'What shape is in the picture I showed you? Answer in one word.',
      retained: (_, recall) => recall.toLowerCase().contains('circle'),
      expectation: 'expected the recalled image to contain "circle"',
    );
  });

  testWidgets('an audio clip stays in its session across a turn on another', (
    tester,
  ) async {
    if (!_audio) {
      _result('audio=not run (OPEN_AUDIO=false)');
      return;
    }
    final audio = (await rootBundle.load(
      'assets/test/test_audio.wav',
    )).buffer.asUint8List();
    await mediaCheck(
      label: 'audio',
      message: () => Message.withAudio(
        text: 'Transcribe this clip.',
        audioBytes: audio,
        isUser: true,
      ),
      // Compare with this session's own transcription. Gemma 4 E2B on a GPU
      // can retain the clip yet answer "Greasy wash water" instead of naming
      // the suit. The generic question deliberately leaks none of those words.
      question: _audioRecallQuestion,
      retained: (transcription, recall) {
        final prompt = _audioContentStems(_audioRecallQuestion);
        final transcript = _audioContentStems(transcription);
        final recalled = _audioContentStems(recall);
        final fixtureInTranscript = transcript.intersection(_audioFixtureStems);
        final unpromptedFixture = _audioFixtureStems.difference(prompt);
        final fixtureInRecall = recalled.intersection(unpromptedFixture);
        final shared = transcript.intersection(recalled);
        // Recalling the assistant's transcription from text history is valid:
        // core deliberately keeps that reply when sessions switch.
        return fixtureInTranscript.length >= 2 &&
            fixtureInRecall.isNotEmpty &&
            shared.isNotEmpty;
      },
      expectation:
          'expected a real fixture transcription and an unprompted fixture '
          'stem shared by its recall',
      verifyIsolation: (other) async {
        final otherRecall = await _ask(
          other,
          'What did the audio clip say? Answer briefly.',
        );
        final leaked = _audioContentStems(
          otherRecall,
        ).intersection(_audioFixtureStems);
        expect(
          leaked,
          isEmpty,
          reason:
              'the session that received no audio recalled fixture stems '
              '$leaked: "$otherRecall"',
        );
      },
    );
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

  testWidgets('refused input fails with ContextLimitException, decode-full '
      'keeps partial text, and the session history is intact', (tester) async {
    final m = await ensureModel();
    final s = await open();
    try {
      await _ask(s, 'My name is Zorblax. Reply with OK only.');
      // Longer than the whole window.
      final tooLong = List.filled(m.maxTokens + 200, 'lorem').join(' ');
      final (_, endTooLong, errorTooLong) = await _turn(
        s,
        'Summarise: $tooLong',
      );
      expect(endTooLong, TurnEnd.contextLimit);
      expect(errorTooLong, isA<ContextLimitException>());
      final name1 = (await _ask(
        s,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      expect(name1, contains('zorblax'), reason: 'history kept after a rewind');

      // Fill the window a chunk at a time until a turn ends contextLimit,
      // then with smaller inputs until even those do not fit.
      final chunk = List.filled(300, 'blue').join(' ');
      TurnEnd? end;
      var turns = 0;
      while (turns < 40) {
        turns++;
        (_, end, _) = await _turn(s, 'Reply with OK only. $chunk');
        if (end == TurnEnd.contextLimit) break;
      }
      expect(end, TurnEnd.contextLimit, reason: 'the window never filled');
      final small = List.filled(40, 'blue').join(' ');
      for (var i = 0; i < 80; i++) {
        turns++;
        (_, end, _) = await _turn(s, 'Reply with OK only. $small');
        if (end == TurnEnd.contextLimit) break;
      }
      final (shortReply, shortEnd, shortError) = await _turn(
        s,
        'What is my name?',
      );
      TurnEnd? again;
      Object? againError;
      if (shortEnd == TurnEnd.contextLimit) {
        (_, again, againError) = await _turn(s, 'Hi');
      }
      _result(
        'contextfull tooLong=$endTooLong recalled=${name1.contains('zorblax')} '
        'filledAfter=$turns short=$shortEnd again=$again',
      );
      if (shortEnd == TurnEnd.contextLimit) {
        if (shortReply.isEmpty) {
          expect(shortError, isA<ContextLimitException>());
        } else {
          // The input fit, then decode consumed the remaining context. A
          // decode-full turn keeps its partial text and does not fail it.
          expect(shortError, isNull);
        }
        expect(again, TurnEnd.contextLimit);
        expect(againError, isA<ContextLimitException>());
      } else {
        expect(shortReply.toLowerCase(), contains('zorblax'));
      }
    } finally {
      await s.close();
    }
  });

  for (final kind in ['openChat', 'createChat']) {
    testWidgets('$kind: a refused input fails the chat turn by name and '
        'leaves the history as the model has it', (tester) async {
      final m = await ensureModel();
      final chat = kind == 'openChat'
          ? await m.openChat(topK: 1)
          : await m.createChat(topK: 1);
      try {
        await chat.addQueryChunk(
          const Message(
            text: 'My name is Zorblax. Reply with OK only.',
            isUser: true,
          ),
        );
        await chat.generateChatResponse();
        final before = [for (final x in chat.fullHistory) x.text];
        final tooLong = List.filled(m.maxTokens + 200, 'lorem').join(' ');
        await chat.addQueryChunk(
          Message(text: 'Summarise: $tooLong', isUser: true),
        );
        Object? error;
        try {
          await chat.generateChatResponse();
        } catch (e) {
          error = e;
        }
        final after = [for (final x in chat.fullHistory) x.text];
        await chat.addQueryChunk(
          const Message(
            text: 'What is my name? Answer with the name only.',
            isUser: true,
          ),
        );
        final name = await chat.generateChatResponse();
        _result(
          'chat/$kind refused=${error.runtimeType} '
          'historyKept=${after.length == before.length}',
        );
        expect(error, isA<ContextLimitException>());
        expect(after, before, reason: 'the refused message is taken back');
        expect((name as TextResponse).token.toLowerCase(), contains('zorblax'));
      } finally {
        await chat.close();
      }
    });
  }

  testWidgets('measures the memory one idle open session adds, the send '
      'call on a switch, and drift over switches (RESULT lines; asserts only '
      'that a switch does not hold the calling isolate)', (tester) async {
    if (!FlutterEdgeAiDiagnostics.isSupported) {
      _result('memory=not supported here');
      return;
    }
    final m = await ensureModel();
    // A first session, so the engine's own buffers are allocated before the
    // baseline.
    final first = await open();
    await _ask(first, 'Reply with OK only.');
    final sameSends = <int>[];
    for (var i = 0; i < 10; i++) {
      await _ask(first, 'Reply with OK only.');
      sameSends.add(m.ffiClient.lastSendCallMicros!);
    }
    Future<(int, int?, int?)> read() async {
      final snapshot = await FlutterEdgeAiDiagnostics.memorySnapshot();
      // Experimental: KGSL (Adreno) only, null elsewhere.
      // ignore: experimental_member_use
      final gpu = await FlutterEdgeAiDiagnostics.gpuMemory();
      return (
        snapshot.anonymousBytes ?? 0,
        snapshot.fileBackedBytes,
        gpu == null ? null : gpu.inAnonymousBytes + gpu.inFileBackedBytes,
      );
    }

    String delta(int? now, int? then) =>
        now == null || then == null ? 'n/a' : _mib(now - then);
    final footprintLabel = Platform.isIOS || Platform.isMacOS
        ? 'phys_footprint'
        : 'anonymous';
    final base = await read();
    var switchBaseline = base;
    const extra = 4;
    final idle = <InferenceModelSession>[];
    try {
      for (var i = 0; i < extra; i++) {
        final s = await open();
        idle.add(s);
        await _ask(s, 'Reply with OK only.');
        // A turn on the first session switches the new one out: its KV is
        // saved as an idle snapshot.
        await _ask(first, 'Reply with OK only.');
        final now = await read();
        _result(
          'idle_sessions=${i + 1} anon_mib=${delta(now.$1, base.$1)} '
          'file_mib=${delta(now.$2, base.$2)} gpu_mib=${delta(now.$3, base.$3)} '
          'maxTokens=${m.maxTokens} backend=${m.activeBackend?.name}',
        );
      }

      // Switches: alternate two sessions.
      final b = idle.first;
      final before = await read();
      switchBaseline = before;
      final switchSends = <int>[];
      final switchNative = <int>[];
      final sw = Stopwatch()..start();
      for (var i = 0; i < _switches; i++) {
        await _ask(i.isEven ? first : b, 'Reply with OK only.');
        switchSends.add(m.ffiClient.lastSendCallMicros!);
        switchNative.add(m.ffiClient.lastSendNativeMicros!);
        if ((i + 1) % 10 == 0) {
          final now = await read();
          _result(
            'switch_memory=${i + 1} ${footprintLabel}_mib=${_mib(now.$1)} '
            '${footprintLabel}_delta_mib=${delta(now.$1, before.$1)} '
            'file_mib=${now.$2 == null ? 'n/a' : _mib(now.$2!)} '
            'gpu_mib=${now.$3 == null ? 'n/a' : _mib(now.$3!)} '
            'gpu_delta_mib=${delta(now.$3, before.$3)}',
          );
        }
      }
      final after = await read();
      _result(
        'switches=$_switches turn_ms='
        '${(sw.elapsedMilliseconds / _switches).toStringAsFixed(0)} '
        'drift_anon_mib=${delta(after.$1, before.$1)} '
        'drift_gpu_mib=${delta(after.$3, before.$3)}',
      );
      _result(
        'send_ui_block_ms same=${(_median(sameSends) / 1000).toStringAsFixed(1)} '
        'switch_median=${(_median(switchSends) / 1000).toStringAsFixed(1)} '
        'switch_max='
        '${(switchSends.reduce((x, y) => x > y ? x : y) / 1000).toStringAsFixed(1)} '
        'switch_native_median='
        '${(_median(switchNative) / 1000).toStringAsFixed(1)} '
        'maxTokens=${m.maxTokens}',
      );
      // A switching send runs on a spawned isolate: the calling isolate is
      // held only to start it.
      expect(_median(switchSends), lessThan(2000));
    } finally {
      for (final s in idle) {
        await s.close();
      }
      await first.close();
      await m.close();
      if (identical(model, m)) model = null;
      final afterClose = await read();
      _result(
        'after_model_close ${footprintLabel}_mib=${_mib(afterClose.$1)} '
        '${footprintLabel}_from_engine_base_mib='
        '${delta(afterClose.$1, base.$1)} '
        '${footprintLabel}_from_switch_base_mib='
        '${delta(afterClose.$1, switchBaseline.$1)} '
        'file_mib=${afterClose.$2 == null ? 'n/a' : _mib(afterClose.$2!)} '
        'gpu_mib=${afterClose.$3 == null ? 'n/a' : _mib(afterClose.$3!)}',
      );
    }
  });
}

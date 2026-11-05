// FFI openSession sessions on the REAL libLiteRtLm, in the host VM (L3, core
// 2.6.0 design §1.1, §6.4b): the checks of the example's
// litertlm_open_sessions_test.dart where an app cannot be staged — macOS
// keeps another app's container closed to a shell. The integration suite is
// what runs on phones and the desktop VMs.
//
// Opt-in, skipped unless LITERTLM_LLM is set:
// - LITERTLM_LLM=<a .litertlm LLM> (Gemma 4 E2B for the image case);
//   LITERTLM_LLM_TYPE=<ModelType name, default gemma4>;
// - LITERTLM_BACKEND=cpu|gpu (default cpu), LITERTLM_MAX_TOKENS (4096),
//   LITERTLM_MEDIA=1 to run the image case, LITERTLM_AUDIO=1 the audio one, LITERTLM_SWITCHES (100);
// - a libLiteRtLm with §1-§25 (native-v0.19.0-a), e.g. the L1 build staged
//   in native/litert_lm/prebuilt/macos_arm64/.
//
//   LITERTLM_LLM=…/gemma-4-E2B-it.litertlm LITERTLM_MEDIA=1 \
//     flutter test test/ffi/open_sessions_native_test.dart
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/ffi_inference_model.dart';
import 'package:flutter_edge_ai_litertlm/src/ffi/litert_lm_client.dart'
    show sendOffMainIsolate;
import 'package:flutter_edge_ai_litertlm/src/ffi/open_session_backing.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine.dart';
import 'package:flutter_edge_ai_litertlm/src/litert_lm_engine_host.dart';
import 'package:flutter_test/flutter_test.dart';

final _env = Platform.environment;
final _modelPath = _env['LITERTLM_LLM'];
final _backend = PreferredBackend.values.byName(
  _env['LITERTLM_BACKEND'] ?? 'cpu',
);
final _maxTokens = int.parse(_env['LITERTLM_MAX_TOKENS'] ?? '4096');
final _media = _env['LITERTLM_MEDIA'] == '1';
final _audio = _env['LITERTLM_AUDIO'] == '1';
final _switches = int.parse(_env['LITERTLM_SWITCHES'] ?? '100');
final _idle = int.parse(_env['LITERTLM_IDLE'] ?? '4');
final _skip = _modelPath == null
    ? 'LITERTLM_LLM is not set'
    : !File(_modelPath!).existsSync()
    ? 'LITERTLM_LLM names no file: $_modelPath'
    : null;

class _Host extends LiteRtLmEngineHost {
  _Host(this.dir);
  final String dir;
  @override
  Future<String> cacheDir() async => dir;
}

final _log = <String>[];

void _result(String line) =>
    // ignore: avoid_print
    print('RESULT open_sessions/${_backend.name} $line');

Future<String> _ask(InferenceModelSession s, String text) async {
  await s.addQueryChunk(Message(text: text, isUser: true));
  final reply = await s.getResponse();
  // ignore: avoid_print
  print('[open] "${_short(text)}" -> "${_short(reply)}"');
  return reply;
}

String _short(String s) {
  final one = s.replaceAll('\n', ' ');
  return one.length > 80 ? '${one.substring(0, 80)}…' : one;
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
  // ignore: avoid_print
  print(
    '[open] turn of ${text.length} chars -> $end '
    '${error == null ? '' : '(${error.runtimeType}) '}"${_short('$reply')}"',
  );
  return ('$reply', end, error);
}

int _median(List<int> xs) => (List.of(xs)..sort())[xs.length ~/ 2];

String _mib(num bytes) => (bytes / (1 << 20)).toStringAsFixed(1);

void main() {
  late FfiInferenceModel model;
  late Directory cache;

  setUpAll(() async {
    if (_skip != null) return;
    // Diagnostic: LITERTLM_SYNC_SEND=1 runs a switching send's native call
    // inline instead of on a spawned isolate.
    if (_env['LITERTLM_SYNC_SEND'] == '1') {
      sendOffMainIsolate = (w) async => w();
    }
    final printer = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null && message.startsWith('[FfiInferenceModel]')) {
        _log.add(message);
      }
      printer(message, wrapWidth: wrapWidth);
    };
    cache = Directory.systemTemp.createTempSync('open_sessions_');
    debugLiteRtLmEngineHost = _Host(cache.path);
    model =
        await const LiteRtLmEngine().createModel(
              InferenceModelSpec(
                name: 'open-sessions',
                modelSource: FileSource(_modelPath!),
                modelType: ModelType.values.byName(
                  _env['LITERTLM_LLM_TYPE'] ?? 'gemma4',
                ),
                fileType: ModelFileType.litertlm,
              ),
              RuntimeConfig(
                maxTokens: _maxTokens,
                modelPath: _modelPath!,
                preferredBackend: _backend,
                supportImage: _media,
                supportAudio: _audio,
              ),
            )
            as FfiInferenceModel;
  });

  tearDownAll(() async {
    if (_skip != null) return;
    await model.close();
    debugLiteRtLmEngineHost = null;
    cache.deleteSync(recursive: true);
  });

  Future<InferenceModelSession> open() => model.openSession(topK: 1);

  test('the load chose native backing', () {
    _result(
      'backing=${model.openSessionBacking.name} '
      'active=${model.activeBackend?.name} noRewind=${model.noRewindReason} '
      'maxTokens=${model.maxTokens}',
    );
    expect(model.openSessionBacking, OpenSessionBacking.native);
  }, skip: _skip);

  test('three interleaved sessions each recall only their own word', () async {
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
        final foreign = [
          for (var j = 0; j < words.length; j++)
            if (j != i && reply.contains(words[j])) j,
        ];
        if (reply.contains(words[i]) && foreign.isEmpty) passed++;
      }
      _result('multiconv=$passed/${words.length}');
      expect(passed, words.length);
    } finally {
      for (final s in sessions) {
        await s.close();
      }
    }
  }, skip: _skip);

  test('an image stays in its session across a turn on another', () async {
    final a = await open();
    final b = await open();
    try {
      await a.addQueryChunk(
        Message.withImage(
          text: 'Look at this picture. Reply with OK only.',
          imageBytes: File(
            '../flutter_edge_ai/example/assets/eg2_vision/circle.png',
          ).readAsBytesSync(),
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
  }, skip: _skip ?? (_media ? null : 'LITERTLM_MEDIA is not 1'));

  test('an audio clip stays in its session across a turn on another', () async {
    final a = await open();
    final b = await open();
    try {
      await a.addQueryChunk(
        Message.withAudio(
          text: 'Transcribe this clip.',
          audioBytes: File(
            '../flutter_edge_ai/example/assets/test/test_audio.wav',
          ).readAsBytesSync(),
          isUser: true,
        ),
      );
      await a.getResponse();
      await _ask(b, 'Name a fruit. One word.');
      // The clip: "She had your dark suit in greasy wash water all year".
      final reply = (await _ask(
        a,
        'In the clip I played you, what was in the greasy wash water? A '
        'few words.',
      )).toLowerCase();
      _result('audio=${reply.contains('suit') ? 'PASS' : 'FAIL'}');
      expect(reply, contains('suit'));
    } finally {
      await a.close();
      await b.close();
    }
  }, skip: _skip ?? (_audio ? null : 'LITERTLM_AUDIO is not 1'));

  test('a stop in one session, a turn on another, and the stopped session '
      'still recalls its turns', () async {
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
      // Diagnostic: LITERTLM_STOP_NO_B=1 leaves the other session's turn out.
      if (_env['LITERTLM_STOP_NO_B'] != '1') {
        await _ask(b, 'Name a colour of the sky. One word.');
      }
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
      if (model.noRewindReason == null) {
        expect(rewound, hasLength(1));
        expect(rebuilt, isEmpty);
      } else {
        expect(rebuilt, hasLength(1));
      }
    } finally {
      await a.close();
      await b.close();
    }
  }, skip: _skip);

  test('a turn stopped before it produced anything is taken out of the '
      'conversation (Rule A): its message is not in the model\'s context, '
      'earlier turns are', () async {
    _log.clear();
    final a = await open();
    try {
      await _ask(a, 'My name is Zorblax. Reply with OK only.');
      // A long input, so the stop lands while native still prefills it.
      final filler = List.filled(1500, 'sea').join(' ');
      await a.addQueryChunk(
        Message(
          text:
              'My favourite colour is purple. Here are some words: $filler. '
              'Write a long story about the sea.',
          isUser: true,
        ),
      );
      final quiet = a.getResponseAsync().join();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      await a.stopGeneration();
      final heard = await quiet;
      final colour = (await _ask(
        a,
        'What is my favourite colour? If I have not said, answer "unknown".',
      )).toLowerCase();
      final name = (await _ask(
        a,
        'What is my name? Answer with the name only.',
      )).toLowerCase();
      final rewound = _log.where((l) => l.contains('rewound the conversation'));
      _result(
        'stopnothing streamed=${heard.length} purple=${colour.contains('purple')} '
        'name=${name.contains('zorblax')} rewound=${rewound.length}',
      );
      expect(name, contains('zorblax'));
      expect(heard, isEmpty, reason: 'the stop must land before any text');
      expect(rewound, hasLength(1));
      expect(colour, isNot(contains('purple')), reason: 'taken out');
    } finally {
      await a.close();
    }
  }, skip: _skip);

  test('an input that does not fit fails its turn with '
      'ContextLimitException (end contextLimit), the session answers '
      'again, and nothing of its history is dropped', () async {
    final s = await open();
    try {
      await _ask(s, 'My name is Zorblax. Reply with OK only.');
      final tooLong = List.filled(model.maxTokens + 200, 'lorem').join(' ');
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
      expect(name1, contains('zorblax'));

      final chunk = List.filled(300, 'blue').join(' ');
      TurnEnd? end;
      var turns = 0;
      while (turns < 40) {
        turns++;
        (_, end, _) = await _turn(s, 'Reply with OK only. $chunk');
        if (end == TurnEnd.contextLimit) break;
      }
      expect(end, TurnEnd.contextLimit, reason: 'the window never filled');
      // Then smaller inputs, until even those do not fit: what is left is
      // then below the bundle's smallest prefill signature.
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
        expect(shortError, isA<ContextLimitException>());
        expect(again, TurnEnd.contextLimit);
        expect(againError, isA<ContextLimitException>());
      } else {
        expect(shortReply.toLowerCase(), contains('zorblax'));
      }
    } finally {
      await s.close();
    }
  }, skip: _skip);

  for (final open in ['openChat', 'createChat']) {
    test('$open: a refused input fails the chat turn by name and leaves the '
        'history as the model has it', () async {
      final chat = open == 'openChat'
          ? await model.openChat(topK: 1)
          : await model.createChat(topK: 1);
      try {
        await chat.addQueryChunk(
          const Message(
            text: 'My name is Zorblax. Reply with OK only.',
            isUser: true,
          ),
        );
        await chat.generateChatResponse();
        final before = [for (final m in chat.fullHistory) m.text];
        final tooLong = List.filled(model.maxTokens + 200, 'lorem').join(' ');
        await chat.addQueryChunk(
          Message(text: 'Summarise: $tooLong', isUser: true),
        );
        Object? error;
        try {
          await chat.generateChatResponse();
        } catch (e) {
          error = e;
        }
        final after = [for (final m in chat.fullHistory) m.text];
        await chat.addQueryChunk(
          const Message(
            text: 'What is my name? Answer with the name only.',
            isUser: true,
          ),
        );
        final name = await chat.generateChatResponse();
        _result(
          'chat/$open refused=${error.runtimeType} '
          'historyKept=${after.length == before.length} '
          'recalled=${'$name'.toLowerCase().contains('zorblax')}',
        );
        expect(error, isA<ContextLimitException>());
        expect(after, before, reason: 'the refused message is taken back');
        expect((name as TextResponse).token.toLowerCase(), contains('zorblax'));
      } finally {
        await chat.close();
      }
    }, skip: _skip);
  }

  test(
    'measures the memory one idle open session adds, the send call on a '
    'switch, and drift over switches (RESULT lines; asserts only that a switch does not hold the calling isolate)',
    () async {
      final first = await open();
      await _ask(first, 'Reply with OK only.');
      // Sends to the same conversation: no switch inside the call.
      final sameSends = <int>[];
      for (var i = 0; i < 10; i++) {
        await _ask(first, 'Reply with OK only.');
        sameSends.add(model.ffiClient.lastSendCallMicros!);
      }
      final base = ProcessInfo.currentRss;
      final extra = _idle;
      final idle = <InferenceModelSession>[];
      final deltas = <int>[];
      var previous = base;
      try {
        for (var i = 0; i < extra; i++) {
          final s = await open();
          idle.add(s);
          await _ask(s, 'Reply with OK only.');
          await _ask(first, 'Reply with OK only.');
          final now = ProcessInfo.currentRss;
          deltas.add(now - previous);
          previous = now;
        }
        _result(
          'idle_session_rss_mib=${_mib((previous - base) / extra)} '
          'maxTokens=${model.maxTokens} deltas_mib=${deltas.map(_mib).join(',')}',
        );
        final b = idle.first;
        final before = ProcessInfo.currentRss;
        final switchSends = <int>[];
        final switchNative = <int>[];
        final sw = Stopwatch()..start();
        for (var i = 0; i < _switches; i++) {
          await _ask(i.isEven ? first : b, 'Reply with OK only.');
          switchSends.add(model.ffiClient.lastSendCallMicros!);
          switchNative.add(model.ffiClient.lastSendNativeMicros!);
          if ((i + 1) % 50 == 0) {
            debugPrint(
              '[open] after ${i + 1} switches: '
              '${_mib(ProcessInfo.currentRss - before)} MiB',
            );
          }
        }
        _result(
          'switches=$_switches turn_ms='
          '${(sw.elapsedMilliseconds / _switches).toStringAsFixed(0)} '
          'drift_rss_mib=${_mib(ProcessInfo.currentRss - before)}',
        );
        _result(
          'send_ui_block_ms same=${(_median(sameSends) / 1000).toStringAsFixed(1)} '
          'switch_median=${(_median(switchSends) / 1000).toStringAsFixed(1)} '
          'switch_max='
          '${(switchSends.reduce((x, y) => x > y ? x : y) / 1000).toStringAsFixed(1)} '
          'switch_native_median='
          '${(_median(switchNative) / 1000).toStringAsFixed(1)} '
          'maxTokens=${model.maxTokens}',
        );
        // A switching send runs on a spawned isolate: the calling isolate is
        // held only to start it.
        expect(_median(switchSends), lessThan(2000));
      } finally {
        for (final s in idle) {
          await s.close();
        }
        await first.close();
      }
    },
    skip: _skip,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

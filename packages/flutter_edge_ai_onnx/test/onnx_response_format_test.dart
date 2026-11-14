// Response formats (PR 9c) and turn ends against the REAL `GenAiFfiClient` and
// the REAL worker loop, over the scripted engine of
// `test/fakes/fake_gen_ai_worker.dart`: which hosts take a format, that the
// schema reaches every generator a guided session creates, that a guided
// session starts a fresh generator after a turn that did not end on its own,
// how each turn ends, and that a cancelled stream's stop names its own turn.
// Real ORT-GenAI guidance is `onnx_response_format_host_smoke_test.dart`.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter_edge_ai/engine.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_client.dart';
import 'package:flutter_edge_ai_onnx/src/ffi/gen_ai_worker.dart'
    show AfterTurn, afterTurn;
import 'package:flutter_edge_ai_onnx/src/onnx_inference_model.dart';
import 'package:flutter_edge_ai_onnx/src/onnx_session.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes/fake_gen_ai_client.dart';
import 'fakes/fake_gen_ai_worker.dart';

List<String> _linesOf(File log) =>
    log.existsSync() ? log.readAsLinesSync() : const <String>[];

Future<void> _waitForLine(File log, String line) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!_linesOf(log).contains(line)) {
    if (DateTime.now().isAfter(deadline)) {
      fail('the worker never logged "$line"; it logged ${_linesOf(log)}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _until(bool Function() condition, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting: $what');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A turn script for the scripted engine (see its header).
String _script(
  List<String> chunks, {
  String? end,
  bool untilStopped = false,
  bool contextFull = false,
  bool echoIsFirstTurn = false,
  bool echoSession = false,
}) => jsonEncode({
  'chunks': chunks,
  'end': ?end,
  'untilStopped': untilStopped,
  'contextFull': contextFull,
  'echoIsFirstTurn': echoIsFirstTurn,
  'echoSession': echoSession,
});

/// The log lines from the [n]th (1-based) `generate:<session>` on.
List<String> _from(File log, String line, int n) {
  final lines = _linesOf(log);
  var seen = 0;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i] == line && ++seen == n) return lines.sublist(i);
  }
  return const [];
}

Future<String> _ask(InferenceModelSession session, String script) async {
  await session.addQueryChunk(Message(text: script, isUser: true));
  return session.getResponse();
}

final _schema = ResponseFormat.jsonSchema({
  'type': 'object',
  'properties': {
    'a': {'type': 'integer'},
  },
  'required': ['a'],
});

final _hostHasGuidance = genAiArchiveHasGuidance(Abi.current());

void main() {
  late Directory tmp;
  setUpAll(() async => tmp = await Directory.systemTemp.createTemp('onnx_rf'));
  // The scripted engine stands in for ORT-GenAI, so the guided path runs on
  // any host with guidance in its archive; which hosts are enabled for apps
  // is the run gate, tested below with the real list.
  setUp(() => debugVerifiedGuidanceAbis = {Abi.current()});
  tearDown(() => debugVerifiedGuidanceAbis = null);
  tearDownAll(() => tmp.delete(recursive: true));

  /// A model on the real client over the scripted engine, loaded from a model
  /// directory with (or without) `tokenizer.json`.
  Future<(OnnxInferenceModel, File)> loaded(
    String name, {
    bool tokenizerJson = true,
    bool tokenizerJsonIsDirectory = false,
  }) async {
    final dir = Directory('${tmp.path}/$name')..createSync();
    final log = File('${dir.path}/worker.log');
    File(
      '${dir.path}/fake_config.json',
    ).writeAsStringSync(jsonEncode({'log': log.path, 'logSettle': true}));
    if (tokenizerJsonIsDirectory) {
      Directory('${dir.path}/tokenizer.json').createSync();
    } else if (tokenizerJson) {
      File('${dir.path}/tokenizer.json').writeAsStringSync('{}');
    }
    final client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
    await client.load(dir.path);
    final model = OnnxInferenceModel(
      client: client,
      maxTokens: 1024,
      modelType: ModelType.general,
      activeBackend: null,
      onClose: () {},
    );
    addTearDown(model.close);
    return (model, log);
  }

  group('which hosts take a format', () {
    test('ORT-GenAI 0.19.0 archives with guidance: the four Microsoft '
        'desktop builds, not iOS or our Android build', () {
      for (final abi in [
        Abi.macosArm64,
        Abi.linuxX64,
        Abi.windowsX64,
        Abi.windowsArm64,
      ]) {
        expect(genAiArchiveHasGuidance(abi), isTrue, reason: '$abi');
      }
      for (final abi in [
        Abi.androidArm64,
        Abi.iosArm64,
        Abi.linuxArm64,
        Abi.macosX64,
      ]) {
        expect(genAiArchiveHasGuidance(abi), isFalse, reason: '$abi');
      }
    });

    test('a host whose archive has guidance is refused until its run has '
        'passed: only macOS arm64 so far', () async {
      debugVerifiedGuidanceAbis = null;
      final (model, _) = await loaded('run_gate');
      expect(guidanceRefusalOf(model.client, abi: Abi.macosArm64), isNull);
      for (final abi in [Abi.linuxX64, Abi.windowsX64, Abi.windowsArm64]) {
        expect(
          guidanceRefusalOf(model.client, abi: abi),
          allOf(contains('$abi'), contains('has not been run')),
          reason: '$abi',
        );
      }
    });

    test(
      'a host whose archive has no guidance is refused, naming it',
      () async {
        final (model, _) = await loaded('android');
        for (final abi in [Abi.androidArm64, Abi.iosArm64]) {
          expect(
            guidanceRefusalOf(model.client, abi: abi),
            allOf(contains('$abi'), contains('without guidance')),
          );
        }
      },
    );

    test('the whole dialect on a host with guidance', () async {
      final (model, _) = await loaded('supported');
      final support = model.structuredOutputSupport;
      expect(support.isSupported, isTrue, reason: support.reason);
      expect(support.keywords, ResponseFormat.dialect);
      expect(support.delivery, StructuredDelivery.incremental);
      expect(model.refusalFor(_schema), isNull);
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a model directory without tokenizer.json is refused at '
        'openSession, not at the first turn', () async {
      final (model, log) = await loaded('no_tokenizer', tokenizerJson: false);
      expect(model.structuredOutputSupport.isSupported, isFalse);
      if (_hostHasGuidance) {
        expect(
          model.structuredOutputSupport.reason,
          contains('tokenizer.json'),
        );
      }
      await expectLater(
        model.openSession(responseFormat: _schema),
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
      expect(model.sessions, isEmpty);
      expect(_linesOf(log).where((l) => l.startsWith('generate')), isEmpty);
    });

    test('tokenizer.json is read when a format is asked for, and must be a '
        'file', () async {
      final (model, _) = await loaded(
        'tokenizer_dir',
        tokenizerJsonIsDirectory: true,
      );
      expect(guidanceRefusalOf(model.client), contains('tokenizer.json'));
      final path = '${tmp.path}/tokenizer_dir/tokenizer.json';
      Directory(path).deleteSync();
      File(path).writeAsStringSync('{}');
      expect(guidanceRefusalOf(model.client), isNull);
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a GenAiClient other than GenAiFfiClient takes no format', () async {
      final model = OnnxInferenceModel(
        client: FakeGenAiClient(),
        maxTokens: 1024,
        modelType: ModelType.general,
        activeBackend: null,
        onClose: () {},
      );
      addTearDown(model.close);
      expect(model.structuredOutputSupport.isSupported, isFalse);
      expect(model.structuredOutputSupport.reason, contains('FakeGenAiClient'));
      await expectLater(
        model.openSession(responseFormat: _schema),
        throwsA(isA<ResponseFormatUnsupportedException>()),
      );
    });
  });

  test('the guidance payload is the caller\'s schema in its order, with '
      'llguidance\'s whitespace fixed', () {
    final format =
        ResponseFormat.jsonSchema({
              'type': 'object',
              'required': ['b'],
              'properties': {
                'b': {'type': 'string'},
              },
            })
            as JsonSchemaResponseFormat;
    final sent = genAiGuidanceSchema(format);
    expect(
      sent,
      '{"type":"object","required":["b"],"properties":{"b":{"type":"string"}},'
      '"x-guidance":{"whitespace_flexible":false,"item_separator":", ",'
      '"key_separator":": "}}',
    );
    expect(
      sent,
      startsWith(format.schemaJson.substring(0, format.schemaJson.length - 1)),
    );
  });

  group('a guided session', () {
    test('sets the schema once, on its generator; a turn cut at its cap is '
        'kept, closed as a finished turn, on that same generator', () async {
      final (model, log) = await loaded('guided');
      final session = await model.openSession(responseFormat: _schema);
      final guided =
          'guidance:1:${genAiGuidanceSchema(_schema as JsonSchemaResponseFormat)}';

      expect(await _ask(session, _script(['{"a": 1}'])), '{"a": 1}');
      expect(_linesOf(log), contains('settle:1:keep'));

      // Cut at the cap: incomplete; its exchange stays in the context, as in
      // core's chat, and the grammar starts again.
      await expectLater(
        _ask(session, _script(['{"a"'], end: 'outputLimit')),
        throwsA(
          isA<IncompleteStructuredOutputException>()
              .having((e) => e.end, 'end', TurnEnd.outputLimit)
              .having((e) => e.partialText, 'partialText', '{"a"'),
        ),
      );
      expect(_linesOf(log).last, 'settle:1:keepCut');
      expect(await _ask(session, _script(['{"a": 3}'])), '{"a": 3}');
      // One generator throughout: never created again.
      expect(_linesOf(log).where((l) => l == guided), hasLength(1));
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a cut turn is settled before a turn queued behind it runs', () async {
      final (model, log) = await loaded('race');
      final session = await model.openSession(responseFormat: _schema);
      await session.addQueryChunk(
        Message(
          text: _script(['{"a"', ': 1'], end: 'outputLimit'),
          isUser: true,
        ),
      );
      final a = expectLater(
        session.getResponse(),
        throwsA(isA<IncompleteStructuredOutputException>()),
      );
      await _waitForLine(log, 'generate:1');
      // Queued while A runs.
      await session.addQueryChunk(
        Message(text: _script(['{"a": 2}']), isUser: true),
      );
      final b = session.getResponse();
      await a;
      expect(await b, '{"a": 2}');
      expect(
        _from(log, 'generate:1', 1).where((l) => !l.startsWith('guidance')),
        ['generate:1', 'settle:1:keepCut', 'generate:1', 'settle:1:keep'],
      );
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a paused cut turn is settled before the next turn, and cancelling '
        'it late settles nothing again', () async {
      final (model, log) = await loaded('race_paused');
      final session = await model.openSession(responseFormat: _schema);
      await session.addQueryChunk(
        Message(
          text: _script(['{"a"', ': 1'], end: 'outputLimit'),
          isUser: true,
        ),
      );
      final paused = session.getResponseAsync().listen(
        (_) {},
        onError: (Object _) {},
      )..pause();
      await _waitForLine(log, 'settle:1:keepCut');
      expect(await _ask(session, _script(['{"a": 2}'])), '{"a": 2}');
      final settled = _linesOf(log);
      await paused.cancel();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(_linesOf(log), settled);
      expect(settled.where((l) => l.startsWith('settle')), [
        'settle:1:keepCut',
        'settle:1:keep',
      ]);
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test(
      'a reply that is not a value of the format is NonConforming',
      () async {
        final (model, _) = await loaded('nonconforming');
        final session = await model.openSession(responseFormat: _schema);
        await expectLater(
          _ask(session, _script(['{"a": "x"}'])),
          throwsA(isA<NonConformingStructuredOutputException>()),
        );
      },
      skip: _hostHasGuidance ? false : 'this host has no guidance',
    );

    test('a prompt that does not fit is refused with the text\'s error, and '
        'leaves the conversation as it was', () async {
      final (model, log) = await loaded('guided_context');
      final session = await model.openSession(responseFormat: _schema);
      expect(await _ask(session, _script(['{"a": 1}'])), '{"a": 1}');
      await expectLater(
        _ask(session, _script([], contextFull: true)),
        throwsA(
          isA<ContextLimitException>().having(
            (e) => e.message,
            'message',
            contains('does not fit'),
          ),
        ),
      );
      expect(await _ask(session, _script(['{"a": 2}'])), '{"a": 2}');
      expect(_linesOf(log).where((l) => l.startsWith('settle')), [
        'settle:1:keep',
        'settle:1:rewind',
        'settle:1:keep',
      ]);
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a stopped turn is incomplete; its exchange is kept, and the next '
        'turn is a value', () async {
      final (model, log) = await loaded('guided_stop');
      final session = await model.openSession(responseFormat: _schema);
      await session.addQueryChunk(
        Message(text: _script(['{"a"'], untilStopped: true), isUser: true),
      );
      final reply = expectLater(
        session.getResponse(),
        throwsA(
          isA<IncompleteStructuredOutputException>()
              .having((e) => e.end, 'end', TurnEnd.stopped)
              .having((e) => e.partialText, 'partialText', '{"a"'),
        ),
      );
      await _waitForLine(log, 'generate:1');
      await session.stopGeneration();
      await reply;
      expect(_linesOf(log).last, 'settle:1:keepStopped');
      expect(await _ask(session, _script(['{"a": 2}'])), '{"a": 2}');
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');

    test('a session closed during its turn ends it closed', () async {
      final (model, log) = await loaded('closed');
      final session = await model.openSession(responseFormat: _schema);
      await session.addQueryChunk(
        Message(text: _script(['{'], untilStopped: true), isUser: true),
      );
      // Attached before the close, which fails the reply.
      final reply = expectLater(
        session.getResponse(),
        throwsA(
          isA<IncompleteStructuredOutputException>().having(
            (e) => e.end,
            'end',
            TurnEnd.closed,
          ),
        ),
      );
      await _waitForLine(log, 'generate:1');
      await session.close();
      await reply;
    }, skip: _hostHasGuidance ? false : 'this host has no guidance');
  });

  group('an unguided session', () {
    test('sends no schema, and keeps a turn at its cap', () async {
      final (model, log) = await loaded('plain');
      final session = await model.openSession();
      await _ask(session, _script(['x'], echoSession: true));
      await _ask(session, _script(['x'], end: 'outputLimit'));
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=3]y',
      );
      expect(_linesOf(log).where((l) => l.startsWith('guidance')), isEmpty);
    });

    test('a window filled during decode keeps its turn, as core\'s chat '
        'does', () async {
      final (model, log) = await loaded('context');
      final session = await model.openSession();
      await _ask(session, _script(['x']));
      await _ask(session, _script(['x'], end: 'contextLimit'));
      expect(_linesOf(log), contains('settle:1:keepCut'));
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=3]y',
      );
    });

    test('a stop keeps its exchange: the next turn has the history with the '
        'stopped turn in it', () async {
      final (model, log) = await loaded('stop');
      final session = await model.openSession();
      await _ask(session, _script(['x']));
      await session.addQueryChunk(
        Message(text: _script(['s'], untilStopped: true), isUser: true),
      );
      final stopped = session.getResponse();
      await _waitForLine(log, 'generate:1');
      await _until(
        () => _linesOf(log).where((l) => l == 'generate:1').length == 2,
        'the second turn to start',
      );
      await session.stopGeneration();
      await stopped;
      expect(_linesOf(log), contains('settle:1:keepStopped'));
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=3]y',
      );
    });

    test('a window filled during decode with no text keeps its turn (only '
        'a stop is taken back)', () async {
      final (model, log) = await loaded('context_no_text');
      final session = await model.openSession();
      await _ask(session, _script(['x']));
      expect(await _ask(session, _script([], end: 'contextLimit')), '');
      expect(_linesOf(log), contains('settle:1:keepCut'));
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=3]y',
      );
    });

    test('a stop before any text keeps nothing of the turn, as core\'s chat '
        'takes it back', () async {
      final (model, log) = await loaded('stop_no_text');
      final session = await model.openSession();
      await _ask(session, _script(['x']));
      await session.addQueryChunk(
        Message(text: _script([], untilStopped: true), isUser: true),
      );
      final stopped = session.getResponse();
      await _until(
        () => _linesOf(log).where((l) => l == 'generate:1').length == 2,
        'the second turn to start',
      );
      await session.stopGeneration();
      expect(await stopped, '');
      expect(_linesOf(log), contains('settle:1:keepStopped'));
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=2]y',
      );
    });

    test('a prompt that does not fit is the text\'s StateError, and the '
        'conversation is left as it was', () async {
      final (model, _) = await loaded('plain_context');
      final session = await model.openSession();
      await _ask(session, _script(['x']));
      await expectLater(
        _ask(session, _script([], contextFull: true)),
        throwsA(isA<ContextLimitException>()),
      );
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        '[session=1 turn=2]y',
      );
    });
  });

  // Design 2.6.0 §3: a refused too-long input is an error on the text with
  // end == contextLimit, on plain and structured sessions, and the engine
  // keeps nothing of the turn.
  test('a refused prompt is an error on the text with end contextLimit, on '
      'a plain and a guided session, and nothing of it is kept', () async {
    final (model, _) = await loaded('refused');
    for (final guided in [false, true]) {
      final session = guided
          ? openGuidedOnnxSession(
              client: model.client,
              modelType: ModelType.general,
              fileType: ModelFileType.onnx,
              sessionId: 50,
              onClose: () {},
              jsonSchema: '{"type":"object"}',
            )
          : OnnxSession(
              client: model.client,
              modelType: ModelType.general,
              fileType: ModelFileType.onnx,
              sessionId: 51,
              onClose: () {},
            );
      expect(
        await _ask(session, _script(['x'], echoSession: true)),
        startsWith('[session=${guided ? 50 : 51} turn=1]'),
      );
      await session.addQueryChunk(
        Message(text: _script([], contextFull: true), isUser: true),
      );
      // ignore: invalid_use_of_protected_member
      final turn = session.startTurn();
      await expectLater(
        turn.text.join(),
        throwsA(isA<ContextLimitException>()),
        reason: '$guided',
      );
      expect(await turn.end, TurnEnd.contextLimit, reason: '$guided');
      // Nothing of the refused turn: the next turn is the session's second.
      expect(
        await _ask(session, _script(['y'], echoSession: true)),
        startsWith('[session=${guided ? 50 : 51} turn=2]'),
        reason: '$guided',
      );
      await session.close();
    }
  });

  test('a prompt fits only when it leaves room for one token', () {
    expect(promptFits(10, 1, 12), isTrue);
    expect(promptFits(10, 2, 12), isFalse);
    expect(promptFits(10, 3, 12), isFalse);
  });

  test('what a turn leaves behind (rule A): kept at its end of sequence and '
      'an unguided cap; kept closed after a stop, a guided cap and a full '
      'window; rewound when refused, failed or closed', () {
    for (final guided in [false, true]) {
      expect(afterTurn(TurnEnd.endOfSequence, guided: guided), AfterTurn.keep);
      expect(afterTurn(TurnEnd.stopped, guided: guided), AfterTurn.keepStopped);
      expect(
        afterTurn(TurnEnd.contextLimit, guided: guided),
        AfterTurn.keepCut,
        reason: 'a window filled during decode',
      );
      expect(
        afterTurn(TurnEnd.contextLimit, guided: guided, refused: true),
        AfterTurn.rewind,
        reason: 'a refused prompt',
      );
      for (final end in [TurnEnd.closed, null]) {
        expect(afterTurn(end, guided: guided), AfterTurn.rewind);
      }
    }
    expect(afterTurn(TurnEnd.outputLimit, guided: false), AfterTurn.keep);
    expect(afterTurn(TurnEnd.outputLimit, guided: true), AfterTurn.keepCut);
  });

  group('how a turn ends', () {
    late GenAiFfiClient client;
    late File log;

    setUp(() async {
      log = File(
        '${tmp.path}/ends_${DateTime.now().microsecondsSinceEpoch}.log',
      );
      client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
      await client.load(jsonEncode({'log': log.path}));
      addTearDown(client.shutdown);
    });

    GenAiTurn turn(String script, {int? session = 1}) =>
        GenAiTurn(userContent: script, sessionId: session, isFirstTurn: true);

    Future<(String, TurnEnd)> run(String script) async {
      final started = startGenAiTurn(client, turn(script));
      final text = await started.text.join();
      return (text, await started.end!);
    }

    test('the engine\'s own end: end of sequence, cap, context', () async {
      expect(await run(_script(['a'])), ('a', TurnEnd.endOfSequence));
      expect(await run(_script(['a'], end: 'outputLimit')), (
        'a',
        TurnEnd.outputLimit,
      ));
      expect(await run(_script(['a'], end: 'contextLimit')), (
        'a',
        TurnEnd.contextLimit,
      ));
    });

    test(
      'a prompt that does not fit fails the text and ends contextLimit',
      () async {
        final started = startGenAiTurn(
          client,
          turn(_script([], contextFull: true)),
        );
        await expectLater(
          started.text.join(),
          throwsA(isA<ContextLimitException>()),
        );
        expect(await started.end, TurnEnd.contextLimit);
      },
    );

    test('a failed turn ends closed, its error on the text', () async {
      final started = startGenAiTurn(client, turn(jsonEncode({'throw': true})));
      await expectLater(started.text.join(), throwsStateError);
      expect(await started.end, TurnEnd.closed);
    });

    test('stopGeneration ends it stopped', () async {
      final started = startGenAiTurn(
        client,
        turn(_script(['a'], untilStopped: true)),
      );
      final text = started.text.join();
      await _waitForLine(log, 'generate:1');
      await client.stopGeneration(sessionId: 1);
      expect(await text, 'a');
      expect(await started.end, TurnEnd.stopped);
    });

    test('a cancelled subscription ends it stopped', () async {
      final started = startGenAiTurn(
        client,
        turn(_script(['a'], untilStopped: true)),
      );
      final first = Completer<void>();
      final sub = started.text.listen((_) {
        if (!first.isCompleted) first.complete();
      });
      await first.future;
      await sub.cancel();
      expect(await started.end, TurnEnd.stopped);
      await _waitForLine(log, 'stopped');
    });

    test('a turn cancelled while it waits behind another ends stopped, '
        'and never runs', () async {
      final running = startGenAiTurn(
        client,
        turn(_script(['a'], untilStopped: true)),
      );
      final runningText = running.text.join();
      await _waitForLine(log, 'generate:1');
      final waiting = startGenAiTurn(client, turn(_script(['b']), session: 2));
      await waiting.text.listen((_) {}).cancel();
      await client.stopGeneration(sessionId: 1);
      await runningText;
      expect(
        await waiting.end!.timeout(const Duration(seconds: 5)),
        TurnEnd.stopped,
      );
      expect(_linesOf(log), isNot(contains('generate:2')));
    });

    test('a shutdown during the turn ends it closed', () async {
      final started = startGenAiTurn(
        client,
        turn(_script(['a'], untilStopped: true)),
      );
      final text = started.text.join();
      await _waitForLine(log, 'generate:1');
      await client.shutdown();
      await text;
      expect(await started.end, TurnEnd.closed);
    });

    test('a client other than GenAiFfiClient reports no end and refuses '
        'guidance', () {
      final fake = FakeGenAiClient();
      expect(startGenAiTurn(fake, turn('x')).end, isNull);
      expect(
        () => startGenAiTurn(fake, turn('x'), guidance: '{}'),
        throwsStateError,
      );
    });
  });

  // #765 review: a stop keyed by session let a consumer that paused one turn
  // and cancelled it after the session's next turn had started stop that
  // next turn.
  test('cancelling a paused stream whose turn ended does not stop the '
      'session\'s next turn', () async {
    final log = File('${tmp.path}/paused.log');
    final client = GenAiFfiClient(workerEntry: fakeGenAiWorkerEntry);
    await client.load(jsonEncode({'log': log.path}));
    addTearDown(client.shutdown);

    final paused =
        client
            .generate(GenAiTurn(userContent: _script(['a']), sessionId: 1))
            .listen((_) {})
          ..pause();

    // The next turn of the same session runs only once the first has ended
    // on the worker.
    final next = client.generate(
      GenAiTurn(userContent: _script(['b'], untilStopped: true), sessionId: 1),
    );
    final firstChunk = Completer<String>();
    final chunks = <String>[];
    final nextDone = Completer<void>();
    next.listen((c) {
      chunks.add(c);
      if (!firstChunk.isCompleted) firstChunk.complete(c);
    }, onDone: nextDone.complete);
    expect(await firstChunk.future, 'b');

    await paused.cancel();
    // Gives a stop sent by the cancel time to land at the next yield.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(_linesOf(log), isNot(contains('stopped')));
    expect(nextDone.isCompleted, isFalse);

    await client.stopGeneration(sessionId: 1);
    await nextDone.future;
    expect(_linesOf(log), contains('stopped'));
  });
}

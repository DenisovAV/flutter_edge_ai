import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_gemma/flutter_gemma.dart'
    show SpeechRecognizer, SpeechSynthesizer;
import 'package:flutter_gemma_speech/src/voice/voice_event.dart';
import 'package:flutter_gemma_speech/src/voice/voice_responder.dart';
import 'package:flutter_gemma_speech/src/voice/voice_session.dart';
import 'package:flutter_test/flutter_test.dart';

// ---- Fakes ----
class _FakeRecognizer implements SpeechRecognizer {
  _FakeRecognizer(this.text);
  final String text;
  int calls = 0;
  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm, {String? language}) async {
    calls++;
    return text;
  }

  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

class _FakeSynth implements SpeechSynthesizer {
  _FakeSynth({this.gate});
  final Completer<void>? gate; // if set, synthesize blocks until completed
  int calls = 0;
  @override
  int get sampleRate => 22050;
  @override
  Future<Uint8List> synthesize(String text) async {
    calls++;
    if (gate != null) await gate!.future;
    return Uint8List.fromList([9, 9, 9]);
  }

  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

/// Records every text it synthesizes (so streaming tests can assert clause
/// boundaries) and returns a distinct non-empty PCM per call. Optionally gates
/// (blocks) and/or throws when a clause contains [throwOn].
class _RecordingSynth implements SpeechSynthesizer {
  _RecordingSynth({this.gate, this.throwOn, this.delay, this.gateFrom});
  final Completer<void>? gate;
  final String? throwOn;
  final Duration? delay; // fakeAsync-controllable in-flight time
  final int? gateFrom; // if set, [gate] only blocks from this call (1-based)
  final List<String> synthesized = [];
  @override
  int get sampleRate => 22050;
  @override
  Future<Uint8List> synthesize(String text) async {
    synthesized.add(text);
    if (delay != null) await Future<void>.delayed(delay!);
    if (gate != null && (gateFrom == null || synthesized.length >= gateFrom!)) {
      await gate!.future;
    }
    if (throwOn != null && text.contains(throwOn!)) {
      throw StateError('synth boom');
    }
    return Uint8List.fromList(List.filled(synthesized.length, 7));
  }

  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

/// A responder whose reply stream the test drives via [ctrl]; `stop` closes it
/// (the contract: stop must end the respond stream). Records stop calls.
class _FakeResponder {
  final ctrl = StreamController<String>();
  int stopCalls = 0;
  bool stopThrows = false;
  int respondCalls = 0;

  VoiceResponder build() => VoiceResponder(
    respond: (userText) {
      respondCalls++;
      return ctrl.stream;
    },
    stop: () async {
      stopCalls++;
      if (stopThrows) throw StateError('stop boom');
      if (!ctrl.isClosed) await ctrl.close();
    },
  );
}

Uint8List _pcm() => Uint8List.fromList([1, 2, 3, 4]);

void main() {
  test(
    'happy path emits Transcript → ReplyText(s) → ReplyAudio → Complete',
    () async {
      final r = _FakeResponder();
      final synth = _FakeSynth();
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hello there'),
        responder: r.build(),
        synthesizer: synth,
      );
      final events = <VoiceEvent>[];
      final sub = session.runTurn(_pcm()).listen(events.add);
      await Future<void>.delayed(Duration.zero); // let transcribe resolve
      r.ctrl.add('Hi');
      r.ctrl.add(' there');
      await r.ctrl.close();
      await sub.asFuture<void>();

      expect(events.map((e) => e.runtimeType).toList(), [
        VoiceTranscriptEvent,
        VoiceReplyTextEvent,
        VoiceReplyTextEvent,
        VoiceReplyAudioEvent,
        VoiceTurnCompleteEvent,
      ]);
      final complete = events.last as VoiceTurnCompleteEvent;
      expect(complete.transcript, 'hello there');
      expect(complete.replyText, 'Hi there');
      expect((events[3] as VoiceReplyAudioEvent).sampleRate, 22050);
      expect(synth.calls, 1);
    },
  );

  test('empty transcript ends the turn with no LLM/TTS call', () async {
    final r = _FakeResponder();
    final synth = _FakeSynth();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('   '),
      responder: r.build(),
      synthesizer: synth,
    );
    final events = await session.runTurn(_pcm()).toList();
    expect(events.map((e) => e.runtimeType).toList(), [
      VoiceTranscriptEvent,
      VoiceTurnCompleteEvent,
    ]);
    expect((events.last as VoiceTurnCompleteEvent).replyText, '');
    expect(r.respondCalls, 0);
    expect(synth.calls, 0);
  });

  test('empty reply ends the turn with no TTS call', () async {
    final r = _FakeResponder();
    final synth = _FakeSynth();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: synth,
    );
    final fut = session.runTurn(_pcm()).toList();
    await Future<void>.delayed(Duration.zero);
    await r.ctrl.close(); // no tokens
    final events = await fut;
    expect(events.map((e) => e.runtimeType).toList(), [
      VoiceTranscriptEvent,
      VoiceTurnCompleteEvent,
    ]);
    expect(synth.calls, 0);
  });

  test('second runTurn while in flight throws StateError synchronously', () {
    final r = _FakeResponder();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: _FakeSynth(),
    );
    session.runTurn(_pcm()).listen((_) {});
    expect(() => session.runTurn(_pcm()), throwsStateError);
  });

  test(
    'interrupt during reply: stop called once, audio skipped, Interrupted carries partial',
    () async {
      final r = _FakeResponder();
      final synth = _FakeSynth();
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: r.build(),
        synthesizer: synth,
      );
      final events = <VoiceEvent>[];
      session.runTurn(_pcm()).listen(events.add);
      await Future<void>.delayed(Duration.zero);
      r.ctrl.add('par');
      await Future<void>.delayed(Duration.zero);
      await session.interrupt();

      expect(r.stopCalls, 1);
      expect(synth.calls, 0);
      expect(events.last, isA<VoiceTurnInterruptedEvent>());
      final it = events.last as VoiceTurnInterruptedEvent;
      expect(it.transcript, 'hi');
      expect(it.partialReplyText, 'par');
    },
  );

  test('interrupt during synthesis suppresses audio', () async {
    final r = _FakeResponder();
    final gate = Completer<void>();
    final synth = _FakeSynth(gate: gate);
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: synth,
    );
    final events = <VoiceEvent>[];
    session.runTurn(_pcm()).listen(events.add);
    await Future<void>.delayed(Duration.zero);
    r.ctrl.add('done');
    await r.ctrl.close(); // LLM finishes naturally → driver enters synthesize()
    await Future<void>.delayed(Duration.zero);
    final interruptFut = session.interrupt(); // lands during synthesize
    gate.complete(); // release synthesize
    await interruptFut;

    expect(events.whereType<VoiceReplyAudioEvent>(), isEmpty);
    expect(events.last, isA<VoiceTurnInterruptedEvent>());
  });

  test('interrupt before any reply token: VoiceTurnInterruptedEvent carries '
      'an empty partialReplyText', () async {
    final r = _FakeResponder();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: _FakeSynth(),
    );
    final events = <VoiceEvent>[];
    session.runTurn(_pcm()).listen(events.add);
    // interrupt() lands immediately — before transcribe() even resolves,
    // so the driver picks it up at the pre-LLM checkpoint (§ the
    // `if (_interruptRequested)` right after the transcript event) and
    // responder.respond() is never called.
    await session.interrupt();

    expect(r.respondCalls, 0);
    final terminal = events.last as VoiceTurnInterruptedEvent;
    expect(terminal.transcript, 'hi');
    expect(terminal.partialReplyText, isEmpty);
  });

  test('interrupt when idle is a no-op (does not call stop)', () async {
    final r = _FakeResponder();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: _FakeSynth(),
    );
    await session.interrupt();
    expect(r.stopCalls, 0);
  });

  test('a throwing stop() is caught; interrupt still terminates', () async {
    final r = _FakeResponder()..stopThrows = true;
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: _FakeSynth(),
    );
    final events = <VoiceEvent>[];
    session.runTurn(_pcm()).listen(events.add);
    await Future<void>.delayed(Duration.zero);
    r.ctrl.add('x');
    await Future<void>.delayed(Duration.zero);
    // stop throws AND never closes ctrl → bounded drain must still terminate.
    await session.interrupt();
    expect(events.last, isA<VoiceTurnInterruptedEvent>());
  });

  test(
    'bounded drain: a stop that does not end the stream still terminates within drainTimeout',
    () {
      fakeAsync((async) {
        final ctrl = StreamController<String>();
        // F2: track whether the reply subscription gets cancelled — R1's
        // detach-not-cancel branch must leave it running.
        var cancelled = false;
        ctrl.onCancel = () {
          cancelled = true;
        };
        final responder = VoiceResponder(
          respond: (_) => ctrl.stream,
          stop: () async {}, // does NOT close the stream
        );
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: responder,
          synthesizer: _FakeSynth(),
        );
        final events = <VoiceEvent>[];
        session.runTurn(_pcm()).listen(events.add);
        async.flushMicrotasks();
        ctrl.add('x');
        async.flushMicrotasks();
        session.interrupt();
        async.elapse(VoiceSession.drainTimeout + const Duration(seconds: 1));
        expect(events.last, isA<VoiceTurnInterruptedEvent>());
        expect(cancelled, isFalse); // R1: detach, never cancel

        // isClosed guard: a token delivered after detach must not be
        // forwarded into the already-torn-down turn.
        final countAfter = events.length;
        ctrl.add('late');
        async.flushMicrotasks();
        expect(events.length, countAfter);
      });
    },
  );

  test('a stop() that never resolves does not wedge interrupt(): '
      'timeout(drainTimeout) still arms the drain timer', () {
    fakeAsync((async) {
      final ctrl = StreamController<String>();
      final responder = VoiceResponder(
        respond: (_) => ctrl.stream, // never ends
        stop: () => Completer<void>().future, // never resolves
      );
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: responder,
        synthesizer: _FakeSynth(),
      );
      final events = <VoiceEvent>[];
      session.runTurn(_pcm()).listen(events.add);
      async.flushMicrotasks();
      ctrl.add('x');
      async.flushMicrotasks();
      session.interrupt();
      async.elapse(VoiceSession.drainTimeout * 2 + const Duration(seconds: 1));

      expect(events.last, isA<VoiceTurnInterruptedEvent>());
    });
  });

  test(
    'a stage failure becomes a stream error (no terminal event after)',
    () async {
      final r = _FakeResponder();
      final session = VoiceSession.custom(
        recognizer: _ThrowingRecognizer(),
        responder: r.build(),
        synthesizer: _FakeSynth(),
      );
      Object? caught;
      await session.runTurn(_pcm()).forEach((_) {}).catchError((Object e) {
        caught = e;
      });
      expect(caught, isA<StateError>());
    },
  );

  test(
    'reply stream error is turn-fatal: stream error surfaces, no terminal event follows',
    () async {
      final r = _FakeResponder();
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: r.build(),
        synthesizer: _FakeSynth(),
      );
      final events = <VoiceEvent>[];
      Object? caught;
      final streamDone = Completer<void>();
      session
          .runTurn(_pcm())
          .listen(
            events.add,
            onError: (Object e) {
              caught = e;
              if (!streamDone.isCompleted) streamDone.complete();
            },
            onDone: () {
              if (!streamDone.isCompleted) streamDone.complete();
            },
          );
      await Future<void>.delayed(Duration.zero);
      r.ctrl.addError(StateError('llm boom'));
      await streamDone.future;

      expect(caught, isA<StateError>());
      expect(events.whereType<VoiceTurnInterruptedEvent>(), isEmpty);
      expect(events.whereType<VoiceTurnCompleteEvent>(), isEmpty);
    },
  );

  test(
    'interrupt then reply stream errors: error wins, interrupt completes without rethrowing',
    () async {
      final ctrl = StreamController<String>();
      var stopCalls = 0;
      final responder = VoiceResponder(
        respond: (_) => ctrl.stream,
        stop: () async {
          stopCalls++;
          // Does NOT close/error the stream itself — the test triggers the
          // failure separately below, while the bounded drain is pending.
        },
      );
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: responder,
        synthesizer: _FakeSynth(),
      );
      final events = <VoiceEvent>[];
      Object? caught;
      final streamDone = Completer<void>();
      session
          .runTurn(_pcm())
          .listen(
            events.add,
            onError: (Object e) {
              caught = e;
              if (!streamDone.isCompleted) streamDone.complete();
            },
            onDone: () {
              if (!streamDone.isCompleted) streamDone.complete();
            },
          );
      await Future<void>.delayed(Duration.zero);
      ctrl.add('par');
      await Future<void>.delayed(Duration.zero);

      final interruptFut = session.interrupt(); // stop() + bounded drain
      await Future<void>.delayed(Duration.zero); // let stop() resolve
      ctrl.addError(StateError('llm boom')); // reply stream fails mid-drain
      await interruptFut; // must complete without rethrowing
      await streamDone.future;

      expect(stopCalls, 1);
      expect(caught, isA<StateError>());
      expect(events.whereType<VoiceTurnInterruptedEvent>(), isEmpty);
      expect(events.whereType<VoiceTurnCompleteEvent>(), isEmpty);
    },
  );

  test(
    'N1: interrupt for turn A parked on a slow stop() does not block barge-in on turn B',
    () {
      fakeAsync((async) {
        // Turn A never reaches the LLM stage below (its interrupt() lands at
        // the transcript checkpoint, before responder.respond() is ever
        // called) — only turn B consumes a reply stream.
        final ctrlB = StreamController<String>();
        var respondCalls = 0;
        var stopCalls = 0;
        final stopAGate = Completer<void>();
        final responder = VoiceResponder(
          respond: (_) {
            respondCalls++;
            return ctrlB.stream;
          },
          stop: () async {
            stopCalls++;
            if (stopCalls == 1) {
              await stopAGate.future; // turn A's stop(): parks indefinitely
            }
            // Turn B's stop() (2nd call): resolves immediately and does NOT
            // close ctrlB — the bounded drain below forces turn B's terminal.
          },
        );
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: responder,
          synthesizer: _FakeSynth(),
        );

        // ---- Turn A: interrupt() called immediately, parks on the slow
        // stop(). Turn A picks up the interrupt at the earliest checkpoint
        // (right after transcribe(), before ever calling responder.respond())
        // and reaches its terminal while interrupt#1 is STILL parked.
        final eventsA = <VoiceEvent>[];
        session.runTurn(_pcm()).listen(eventsA.add);
        session.interrupt(); // interrupt#1 — parks on stopAGate
        async.flushMicrotasks();
        expect(stopCalls, 1);
        expect(eventsA.last, isA<VoiceTurnInterruptedEvent>());
        expect(respondCalls, 0); // never reached the LLM stage for A

        // ---- Turn B starts + barges in while interrupt#1 is still parked ----
        final eventsB = <VoiceEvent>[];
        session.runTurn(_pcm()).listen(eventsB.add);
        async.flushMicrotasks();
        ctrlB.add('partial-b');
        async.flushMicrotasks();

        session.interrupt(); // interrupt#2 — must target turn B, not no-op
        async.flushMicrotasks();
        // N1: stop() really called again for B — the barge-in was not
        // silently swallowed by a session-scoped in-flight guard.
        expect(stopCalls, 2);

        // Force turn B's bounded drain (ctrlB never closes).
        async.elapse(VoiceSession.drainTimeout + const Duration(seconds: 1));
        expect(eventsB.last, isA<VoiceTurnInterruptedEvent>());
        final itB = eventsB.last as VoiceTurnInterruptedEvent;
        expect(itB.partialReplyText, 'partial-b');

        // Release interrupt#1 so it can settle without leaking timers.
        stopAGate.complete();
        async.flushMicrotasks();
      });
    },
  );

  test('same-turn concurrent interrupt(): a second interrupt() on the SAME '
      'in-flight turn is a true no-op — stop() called once, both futures '
      'resolve, exactly one terminal event', () async {
    final r = _FakeResponder();
    final session = VoiceSession.custom(
      recognizer: _FakeRecognizer('hi'),
      responder: r.build(),
      synthesizer: _FakeSynth(),
    );
    final events = <VoiceEvent>[];
    session.runTurn(_pcm()).listen(events.add);
    await Future<void>.delayed(Duration.zero);
    r.ctrl.add('tok');
    await Future<void>.delayed(Duration.zero);

    // Two interrupt() calls on the SAME in-flight turn, neither awaited
    // before the other starts: #1 is the real barge-in (calls stop());
    // #2 must see `identical(_interruptingController, controller)` and
    // take the true no-op branch (just await the shared terminal) instead
    // of re-calling stop() or re-arming the drain timer.
    final f1 = session.interrupt();
    final f2 = session.interrupt();
    await Future.wait([f1, f2]); // both must resolve without rethrowing

    expect(r.stopCalls, 1); // #2 must NOT re-call stop()
    expect(events.whereType<VoiceTurnInterruptedEvent>(), hasLength(1));
    final terminal = events.last as VoiceTurnInterruptedEvent;
    expect(terminal.partialReplyText, 'tok');
  });

  group('streamAudio (clause-by-clause TTS)', () {
    test('synthesizes clause-by-clause: isFinal:false chunks then a zero-byte '
        'isFinal:true marker', () async {
      final r = _FakeResponder();
      final synth = _RecordingSynth();
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: r.build(),
        synthesizer: synth,
        streamAudio: true,
      );
      final events = <VoiceEvent>[];
      final sub = session.runTurn(_pcm()).listen(events.add);
      await Future<void>.delayed(Duration.zero);
      r.ctrl.add('Hello there. '); // complete clause → synth now
      await Future<void>.delayed(Duration.zero);
      r.ctrl.add('How are you today?'); // no trailing space → flushed on close
      await r.ctrl.close();
      await sub.asFuture<void>();

      // Two clauses synthesized in order (the tail via flush()).
      expect(synth.synthesized, ['Hello there. ', 'How are you today?']);
      final audio = events.whereType<VoiceReplyAudioEvent>().toList();
      expect(audio, hasLength(3)); // 2 chunks + 1 sentinel
      expect(audio[0].isFinal, isFalse);
      expect(audio[1].isFinal, isFalse);
      expect(audio[2].isFinal, isTrue);
      expect(audio[2].pcm, isEmpty); // zero-byte end-of-audio marker
      expect(audio.where((a) => a.isFinal), hasLength(1)); // exactly one final
      expect(events.last, isA<VoiceTurnCompleteEvent>());
      expect(
        (events.last as VoiceTurnCompleteEvent).replyText,
        'Hello there. How are you today?',
      );
    });

    test(
      'a single short reply is synthesized via flush → one chunk + sentinel',
      () async {
        final r = _FakeResponder();
        final synth = _RecordingSynth();
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: r.build(),
          synthesizer: synth,
          streamAudio: true,
        );
        final events = <VoiceEvent>[];
        final sub = session.runTurn(_pcm()).listen(events.add);
        await Future<void>.delayed(Duration.zero);
        r.ctrl.add('Hi.'); // short + no trailing space → only via flush()
        await r.ctrl.close();
        await sub.asFuture<void>();

        expect(synth.synthesized, ['Hi.']);
        final audio = events.whereType<VoiceReplyAudioEvent>().toList();
        expect(audio, hasLength(2));
        expect(audio[0].isFinal, isFalse);
        expect(audio[1].isFinal, isTrue);
        expect(audio[1].pcm, isEmpty);
      },
    );

    test(
      'an empty reply → no audio, no sentinel, VoiceTurnComplete("")',
      () async {
        final r = _FakeResponder();
        final synth = _RecordingSynth();
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: r.build(),
          synthesizer: synth,
          streamAudio: true,
        );
        final events = <VoiceEvent>[];
        final sub = session.runTurn(_pcm()).listen(events.add);
        await Future<void>.delayed(Duration.zero);
        await r.ctrl.close(); // no tokens
        await sub.asFuture<void>();

        expect(synth.synthesized, isEmpty);
        expect(events.whereType<VoiceReplyAudioEvent>(), isEmpty);
        expect(events.last, isA<VoiceTurnCompleteEvent>());
        expect((events.last as VoiceTurnCompleteEvent).replyText, '');
      },
    );

    test(
      'barge-in during synthesis suppresses further chunks → Interrupted',
      () async {
        final r = _FakeResponder();
        final gate = Completer<void>();
        final synth = _RecordingSynth(gate: gate);
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: r.build(),
          synthesizer: synth,
          streamAudio: true,
        );
        final events = <VoiceEvent>[];
        final sub = session.runTurn(_pcm()).listen(events.add);
        await Future<void>.delayed(Duration.zero);
        r.ctrl.add('First clause here. '); // pump starts synth, blocks on gate
        await Future<void>.delayed(Duration.zero);
        final interruptFut = session.interrupt(); // barge-in mid-synth
        await Future<void>.delayed(Duration.zero);
        gate.complete(); // release the in-flight synthesize
        await interruptFut;
        await sub.asFuture<void>();

        // The in-flight synth completes but its chunk is suppressed (barge-in set
        // _interruptRequested before the pump's post-synth check).
        expect(events.whereType<VoiceReplyAudioEvent>(), isEmpty);
        expect(events.last, isA<VoiceTurnInterruptedEvent>());
        expect(r.stopCalls, 1);
      },
    );

    test(
      'a synthesize error is turn-fatal (stream error), earlier chunks kept',
      () async {
        final r = _FakeResponder();
        final synth = _RecordingSynth(throwOn: 'boom');
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: r.build(),
          synthesizer: synth,
          streamAudio: true,
        );
        final events = <VoiceEvent>[];
        final errors = <Object>[];
        // The pump-error path ends the turn on its own (no ctrl.close() from the
        // test), possibly before we start awaiting — so complete on onDone rather
        // than asFuture() (which hangs if the stream already closed).
        final done = Completer<void>();
        session
            .runTurn(_pcm())
            .listen(events.add, onError: errors.add, onDone: done.complete);
        await Future<void>.delayed(Duration.zero);
        r.ctrl.add('Good clause here. '); // synth ok → chunk
        await Future<void>.delayed(Duration.zero);
        r.ctrl.add(
          'boom clause here. ',
        ); // synth throws → pump error stops the LLM
        await done.future;

        expect(errors, isNotEmpty);
        expect(errors.first, isA<StateError>());
        // The first chunk was emitted before the error.
        expect(
          events.whereType<VoiceReplyAudioEvent>().where((a) => !a.isFinal),
          isNotEmpty,
        );
        // No terminal event after a fatal error.
        expect(events.whereType<VoiceTurnCompleteEvent>(), isEmpty);
        expect(events.whereType<VoiceTurnInterruptedEvent>(), isEmpty);
        // ...and NO isFinal:true sentinel — that marker is successful-turn-only.
        expect(
          events.whereType<VoiceReplyAudioEvent>().where((a) => a.isFinal),
          isEmpty,
        );
      },
    );

    test(
      'forced-drain barge-in during synthesis terminates within drainTimeout, '
      'suppresses the in-flight chunk',
      () {
        fakeAsync((async) {
          final ctrl = StreamController<String>();
          final responder = VoiceResponder(
            respond: (_) => ctrl.stream,
            stop: () async {}, // does NOT close the stream → forces the drain
          );
          final synth = _RecordingSynth(delay: const Duration(seconds: 2));
          final session = VoiceSession.custom(
            recognizer: _FakeRecognizer('hi'),
            responder: responder,
            synthesizer: synth,
            streamAudio: true,
          );
          final events = <VoiceEvent>[];
          session.runTurn(_pcm()).listen(events.add);
          async.flushMicrotasks();
          ctrl.add('Hello there now. '); // a clause → pump starts synth (2s)
          async.flushMicrotasks();
          session.interrupt(); // barge-in while the synth is in flight
          // Elapse past the 2s synth AND the drain timeout: the in-flight synth
          // completes but its chunk is suppressed, then the drain forces the
          // terminal — interrupt() must not wedge on the uncancellable synth.
          async.elapse(VoiceSession.drainTimeout + const Duration(seconds: 3));
          async.flushMicrotasks();

          expect(events.last, isA<VoiceTurnInterruptedEvent>());
          expect(synth.synthesized, ['Hello there now. ']); // exactly one synth
          // Barge-in landed during the synth → the chunk was suppressed, so no
          // audio event was ever emitted.
          expect(events.whereType<VoiceReplyAudioEvent>(), isEmpty);
        });
      },
    );

    test('barge-in AFTER a chunk is emitted keeps that chunk, suppresses the rest, '
        'emits no sentinel → Interrupted', () async {
      final r = _FakeResponder();
      // Gate only the SECOND synth: chunk #1 is delivered, then barge-in lands
      // while synth #2 is in flight (the between-chunks case the other barge-in
      // test can't reach — it gates the very first synth).
      final gate = Completer<void>();
      final synth = _RecordingSynth(gate: gate, gateFrom: 2);
      final session = VoiceSession.custom(
        recognizer: _FakeRecognizer('hi'),
        responder: r.build(),
        synthesizer: synth,
        streamAudio: true,
      );
      final events = <VoiceEvent>[];
      final sub = session.runTurn(_pcm()).listen(events.add);
      await Future<void>.delayed(Duration.zero);
      r.ctrl.add('First clause here. '); // synth #1 ok → chunk emitted
      await Future<void>.delayed(Duration.zero);
      r.ctrl.add('Second clause here. '); // synth #2 blocks on the gate
      await Future<void>.delayed(Duration.zero);
      final interruptFut = session.interrupt(); // barge-in between chunks
      await Future<void>.delayed(Duration.zero);
      gate.complete(); // release the in-flight synth #2
      await interruptFut;
      await sub.asFuture<void>();

      final audio = events.whereType<VoiceReplyAudioEvent>().toList();
      // Exactly the first chunk survived; the second is suppressed post-synth.
      expect(audio, hasLength(1));
      expect(audio.single.isFinal, isFalse);
      // No isFinal:true sentinel on the interrupt path (Gap B, interrupt side).
      expect(audio.where((a) => a.isFinal), isEmpty);
      expect(events.last, isA<VoiceTurnInterruptedEvent>());
      expect(r.stopCalls, 1);
    });

    test(
      'when the synth pump AND the LLM stream both error, the LLM error wins',
      () async {
        final ctrl = StreamController<String>();
        final responder = VoiceResponder(
          respond: (_) => ctrl.stream,
          // The pump error calls stop(); model that as the LLM stream erroring
          // too (so both replyError and pumpError are set in the same turn).
          stop: () async {
            if (!ctrl.isClosed) {
              ctrl.addError(StateError('llm boom'));
              await ctrl.close();
            }
          },
        );
        final synth = _RecordingSynth(throwOn: 'boom');
        final session = VoiceSession.custom(
          recognizer: _FakeRecognizer('hi'),
          responder: responder,
          synthesizer: synth,
          streamAudio: true,
        );
        final events = <VoiceEvent>[];
        final errors = <Object>[];
        final done = Completer<void>();
        session
            .runTurn(_pcm())
            .listen(events.add, onError: errors.add, onDone: done.complete);
        await Future<void>.delayed(Duration.zero);
        // synth throws → pump error → stop() → LLM stream also errors.
        ctrl.add('boom clause here. ');
        await done.future;

        // Priority: the LLM error wins; exactly one error surfaces.
        expect(errors, hasLength(1));
        expect((errors.single as StateError).message, 'llm boom');
        expect(events.whereType<VoiceTurnCompleteEvent>(), isEmpty);
        expect(events.whereType<VoiceTurnInterruptedEvent>(), isEmpty);
      },
    );
  });
}

class _ThrowingRecognizer implements SpeechRecognizer {
  @override
  String? language;

  @override
  Future<String> transcribe(Uint8List pcm, {String? language}) async =>
      throw StateError('stt boom');
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

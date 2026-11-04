// What each session's generator holds, turn by turn, and what a settled turn
// leaves in it (`gen_ai_worker.dart`'s `afterTurn`). Pure Dart over
// [GeneratorOps], so the rules — keep, keep a stopped exchange, rewind, and
// the rebuild from text where a rewind fails — are tested without a native
// library (`test/gen_ai_turns_test.dart`); `_FfiGenAiEngine` drives it with
// ORT-GenAI. src-only, not barrel-exported.
import 'package:flutter_edge_ai/engine.dart' show TurnEnd;

import 'gen_ai_worker.dart' show AfterTurn;

/// The calls [SessionTurns] makes on one session's live generator.
abstract interface class GeneratorOps {
  /// Tokens the generator holds (`OgaGenerator_GetSequenceCount`).
  int get length;

  /// The token at [index] (`OgaGenerator_GetSequenceData`).
  int tokenAt(int index);

  /// `OgaGenerator_RewindTo`; throws where the model cannot rewind.
  void rewindTo(int length);

  /// `OgaGenerator_AppendTokens`.
  void append(List<int> tokens);
}

/// How a turn that returned ended, from what the generator says:
/// [stopped] when it stopped on a request; else, when the generator is done,
/// [TurnEnd.contextLimit] if it holds the whole window and
/// [TurnEnd.endOfSequence] if not; else [TurnEnd.outputLimit] (its cap came
/// first).
TurnEnd classifyTurnEnd({
  required bool stopped,
  required bool done,
  required int length,
  required int contextWindow,
}) {
  if (stopped) return TurnEnd.stopped;
  if (!done) return TurnEnd.outputLimit;
  return length >= contextWindow ? TurnEnd.contextLimit : TurnEnd.endOfSequence;
}

/// Each session's conversation as text, and its turn in flight.
///
/// The history mirrors what the session's generator holds — its system
/// message and every exchange in it — so a generator that had to be dropped
/// is rebuilt from it. Null keys the legacy session.
final class SessionTurns {
  SessionTurns({
    required this.contextWindow,
    this.endOfTurnToken,
    required this.onRewindFailure,
  });

  /// `max_length`: the window every generator has.
  final int contextWindow;

  /// The token that closes a finished turn, as the model last ended one —
  /// what a stopped turn is closed with. Set from genai_config.json until the
  /// model has ended a turn ([finished]).
  int? endOfTurnToken;

  /// Called when a rewind fails, with the error; the session is then rebuilt
  /// from its history.
  final void Function(Object error) onRewindFailure;

  final Map<int?, List<Map<String, String>>> _history = {};
  final Map<int?, int> _turnStart = {};
  final Map<int?, (String user, StringBuffer reply)> _exchange = {};

  /// The history of [session], for a generator created now (read-only).
  List<Map<String, String>> history(int? session) =>
      List.unmodifiable(_history[session] ?? const []);

  /// A first turn: the history starts again from [system] and [seed].
  void begin(int? session, {String? system, List<Map<String, String>>? seed}) {
    _exchange.remove(session);
    _turnStart.remove(session);
    _history[session] = [
      if (system?.isNotEmpty ?? false) {'role': 'system', 'content': system!},
      ...?seed,
    ];
  }

  /// The turn of [session] starts on a generator holding [length] tokens.
  void started(int? session, int length) {
    _exchange.remove(session);
    _turnStart[session] = length;
    _history[session] ??= [];
  }

  /// [user]'s prompt reached the generator.
  void prefilled(int? session, String user) =>
      _exchange[session] = (user, StringBuffer());

  /// A decoded piece of the reply.
  void emitted(int? session, String piece) =>
      _exchange[session]?.$2.write(piece);

  /// The turn ended on its own with [token].
  void finished(int token) => endOfTurnToken = token;

  /// The session is gone (released, or reset for a first turn).
  void forget(int? session) {
    _history.remove(session);
    _turnStart.remove(session);
    _exchange.remove(session);
  }

  /// Settles [session]'s last turn on [generator] (null: it has none) as
  /// [how] says. [drop] destroys the session's generator, so its next turn
  /// rebuilds it from [history]. Returns false when a rewind failed and the
  /// generator was dropped.
  bool settle(
    int? session,
    AfterTurn how, {
    required GeneratorOps? generator,
    required void Function() drop,
  }) {
    final exchange = _exchange.remove(session);
    final start = _turnStart.remove(session);
    final history = _history[session];
    void remember() {
      if (exchange == null || history == null) return;
      history
        ..add({'role': 'user', 'content': exchange.$1})
        ..add({'role': 'assistant', 'content': exchange.$2.toString()});
    }

    switch (how) {
      case AfterTurn.keep:
        remember();
        return true;
      case AfterTurn.rewind:
        return _rewind(generator, start, drop);
      case AfterTurn.keepStopped:
        return _closeStopped(generator, start, exchange, drop, remember);
    }
  }

  /// [generator] back to [start], the turn gone from it and from the
  /// history. Where the model cannot rewind, it is dropped: the history
  /// (which never got the turn) rebuilds it.
  bool _rewind(GeneratorOps? generator, int? start, void Function() drop) {
    if (generator == null || start == null) return true;
    if (generator.length == start) return true;
    try {
      generator.rewindTo(start);
      return true;
    } catch (e) {
      drop();
      onRewindFailure(e);
      return false;
    }
  }

  /// A turn cut short ([AfterTurn.keepStopped]): its tokens stay — the
  /// prompt and the reply as far as the user saw it — closed with
  /// [endOfTurnToken], so the context is that of a turn whose reply ended
  /// there. The last token is rewound and appended again with the end token:
  /// the rewind resets a guided session's grammar, and tokens appended after
  /// a rewind are never committed into it.
  ///
  /// A generator holding the whole window — a window filled during decode —
  /// has no room for the end token: it keeps the turn as it is, and the
  /// grammar was already reset when the generator became done at
  /// max_length. Where the turn streamed no text (core's chat takes such a
  /// turn back), nothing was prefilled, or no end token is known, the turn
  /// is rewound to [start] instead — its prompt too — gone from the context
  /// and so not recorded. Where a rewind throws, the generator is dropped
  /// and the exchange recorded, so the rebuild from the history holds it.
  bool _closeStopped(
    GeneratorOps? generator,
    int? start,
    (String, StringBuffer)? exchange,
    void Function() drop,
    void Function() remember,
  ) {
    if (generator == null || start == null) return true;
    final length = generator.length;
    final end = endOfTurnToken;
    // A turn that streamed no text is one core's chat takes back: nothing of
    // it stays, its prompt included.
    if (exchange == null ||
        exchange.$2.isEmpty ||
        end == null ||
        length <= start) {
      return _rewind(generator, start, drop);
    }
    // Rewinding one token and appending two needs one free place; an
    // AppendTokens may fill the window exactly.
    if (length >= contextWindow) {
      remember();
      return true;
    }
    try {
      final last = generator.tokenAt(length - 1);
      generator
        ..rewindTo(length - 1)
        ..append([last, end]);
      remember();
      return true;
    } catch (e) {
      // The generator may be anywhere between the two calls: rebuild it from
      // the history, which keeps the exchange.
      drop();
      remember();
      onRewindFailure(e);
      return false;
    }
  }
}

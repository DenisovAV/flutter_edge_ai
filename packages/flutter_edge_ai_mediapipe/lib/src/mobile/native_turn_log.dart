import 'dart:typed_data';

/// One input a mobile session handed to its native MediaPipe session.
sealed class NativeInput {
  const NativeInput();
}

/// A prompt chunk, as sent (turn markers and all).
final class NativeText extends NativeInput {
  const NativeText(this.prompt);
  final String prompt;
}

final class NativeImage extends NativeInput {
  const NativeImage(this.bytes);
  final Uint8List bytes;
}

final class NativeAudio extends NativeInput {
  const NativeAudio(this.bytes);
  final Uint8List bytes;
}

/// What a mobile session's native MediaPipe session holds, in order, so that
/// a turn can be taken back out of it.
///
/// MediaPipe cannot take a queued chunk back, nor roll its context back to
/// before a turn. A turn that failed, or that was stopped before any text,
/// is not kept by the chat (rule A), so the session must not keep it either:
/// [takeBack] returns what the session held before that turn, which the
/// session replays into a fresh native session.
final class NativeTurnLog {
  final List<NativeInput> _inputs = [];

  /// Where the inputs of the current turn start; null between turns.
  int? _turnStart;

  /// The current turn carried the session's system instruction.
  bool _turnCarriesSystemInstruction = false;

  /// Images or audio of a kept turn were let go (see [kept]).
  bool _mediaDropped = false;

  /// Records [input], sent for the current turn.
  void stage(NativeInput input) {
    _turnStart ??= _inputs.length;
    _inputs.add(input);
  }

  /// The current turn's first user message carried the system instruction.
  void stagedSystemInstruction() => _turnCarriesSystemInstruction = true;

  /// The turn is kept: the native session holds its inputs and [reply] (the
  /// model's text as a prompt chunk, or null for none).
  ///
  /// The images and audio of kept turns are let go: holding every one for
  /// the session's life would cost their bytes again in Dart, for a replay
  /// that happens only after a take-back. A replay then carries their
  /// turns' text alone, as a rebuilt LiteRT-LM open session does.
  void kept(String? reply) {
    if (reply != null) _inputs.add(NativeText(reply));
    final before = _inputs.length;
    _inputs.removeWhere((input) => input is! NativeText);
    if (_inputs.length != before) _mediaDropped = true;
    _turnStart = null;
    _turnCarriesSystemInstruction = false;
  }

  /// Takes the current turn back: what the native session held before it,
  /// to replay, and whether the turn carried the system instruction (which
  /// the next turn must then send again). Null when the turn staged nothing.
  ({List<NativeInput> before, bool systemInstruction, bool mediaDropped})?
  takeBack() {
    final start = _turnStart;
    final systemInstruction = _turnCarriesSystemInstruction;
    _turnStart = null;
    _turnCarriesSystemInstruction = false;
    if (start == null) return null;
    _inputs.removeRange(start, _inputs.length);
    return (
      before: List.unmodifiable(_inputs),
      systemInstruction: systemInstruction,
      mediaDropped: _mediaDropped,
    );
  }
}

/// Builds a session's native session again and replays [before] into it,
/// after a turn was taken back. Returns the failure, if any, for the session
/// to keep: it cannot be used after it. Never throws, so the turn keeps the
/// engine's own error. A session [isClosed] meanwhile gets nothing replayed,
/// and what was built for it is closed again.
Future<Object?> rebuildNativeSession({
  required List<NativeInput> before,
  required bool mediaDropped,
  required Future<void> Function() recreate,
  required Future<void> Function() closeRebuilt,
  required bool Function() isClosed,
  required Future<void> Function(NativeInput input) send,
}) async {
  try {
    await recreate();
    if (isClosed()) {
      await closeRebuilt();
      return null;
    }
    if (mediaDropped) {
      // Release builds too: the model sees the earlier turns' text only.
      // ignore: avoid_print
      print(
        '[flutter_edge_ai_mediapipe] a turn was taken back: the session was '
        "rebuilt from the earlier turns' text; their images and audio are "
        'not replayed.',
      );
    }
    for (final input in before) {
      if (isClosed()) return null;
      await send(input);
    }
    return null;
  } catch (error) {
    if (isClosed()) return null;
    // Release builds too: the session is unusable from here on.
    // ignore: avoid_print
    print(
      '[flutter_edge_ai_mediapipe] the native session could not be rebuilt '
      'after a turn was taken back ($error); open a new session.',
    );
    return error;
  }
}

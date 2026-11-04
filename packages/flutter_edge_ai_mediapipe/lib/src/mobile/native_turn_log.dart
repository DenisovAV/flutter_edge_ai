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

  /// Records [input], sent for the current turn.
  void stage(NativeInput input) {
    _turnStart ??= _inputs.length;
    _inputs.add(input);
  }

  /// The current turn's first user message carried the system instruction.
  void stagedSystemInstruction() => _turnCarriesSystemInstruction = true;

  /// The turn is kept: the native session holds its inputs and [reply] (the
  /// model's text as a prompt chunk, or null for none).
  void kept(String? reply) {
    if (reply != null) _inputs.add(NativeText(reply));
    _turnStart = null;
    _turnCarriesSystemInstruction = false;
  }

  /// Takes the current turn back: what the native session held before it,
  /// to replay, and whether the turn carried the system instruction (which
  /// the next turn must then send again). Null when the turn staged nothing.
  ({List<NativeInput> before, bool systemInstruction})? takeBack() {
    final start = _turnStart;
    final systemInstruction = _turnCarriesSystemInstruction;
    _turnStart = null;
    _turnCarriesSystemInstruction = false;
    if (start == null) return null;
    _inputs.removeRange(start, _inputs.length);
    return (
      before: List.unmodifiable(_inputs),
      systemInstruction: systemInstruction,
    );
  }
}

import 'dart:typed_data';

/// One event in a voice turn. Sealed — the vocabulary is designed to cover the
/// streaming/barge-in endgame; later phases emit MORE of these events, never
/// new subtypes. (Design spec §4.1.)
///
/// NOTE: this grammar assumes turns are SERIALIZED — one turn's events (up to
/// its terminal, [VoiceTurnCompleteEvent] or [VoiceTurnInterruptedEvent])
/// fully precede the next turn's events. That's why no `turnId` correlation
/// field exists in v1: a future full-duplex phase (concurrent/overlapping
/// turns) must either preserve strict serialization or add a `turnId` to
/// disambiguate which turn an event belongs to.
sealed class VoiceEvent {
  const VoiceEvent();
}

/// Recognized user speech. v1 emits exactly one with isFinal = true.
class VoiceTranscriptEvent extends VoiceEvent {
  const VoiceTranscriptEvent(this.text, {required this.isFinal});
  final String text;
  final bool isFinal;
  @override
  String toString() => 'VoiceTranscriptEvent("$text", isFinal: $isFinal)';
}

/// A chunk of the LLM's streamed text reply (token granularity in v1).
class VoiceReplyTextEvent extends VoiceEvent {
  const VoiceReplyTextEvent(this.chunk);
  final String chunk;
  @override
  String toString() => 'VoiceReplyTextEvent("$chunk")';
}

/// Synthesized reply audio: 16-bit LE mono PCM at [sampleRate].
///
/// One-shot mode (default) emits exactly one event with `isFinal: true` — the
/// whole reply. Streaming mode (`VoiceSession(streamAudio: true)`) emits the
/// reply as several `isFinal: false` chunks followed by a single zero-byte
/// `isFinal: true` marker. A successful NON-EMPTY turn ends with exactly one
/// `isFinal: true` (an empty-reply turn is successful but emits no audio at
/// all); an errored or interrupted turn emits no `isFinal: true` — though an
/// interrupted streaming turn may already have emitted `isFinal: false` chunks.
class VoiceReplyAudioEvent extends VoiceEvent {
  const VoiceReplyAudioEvent(
    this.pcm, {
    required this.sampleRate,
    required this.isFinal,
  });
  final Uint8List pcm;
  final int sampleRate;
  final bool isFinal;
  @override
  String toString() =>
      'VoiceReplyAudioEvent(${pcm.length} bytes, sampleRate: $sampleRate, isFinal: $isFinal)';
}

/// Terminal in v1: the turn finished normally.
class VoiceTurnCompleteEvent extends VoiceEvent {
  const VoiceTurnCompleteEvent(this.transcript, this.replyText);
  final String transcript;
  final String replyText;
  @override
  String toString() =>
      'VoiceTurnCompleteEvent(transcript: "$transcript", replyText: "$replyText")';
}

/// Terminal: the turn was cut short by [VoiceSession.interrupt] (barge-in).
/// Carries what was produced so the caller can reconcile app state and (for
/// fromChat) chat history from the caller-owned `chat.fullHistory` — there is
/// deliberately no `historyRecorded` flag (§12 B2).
class VoiceTurnInterruptedEvent extends VoiceEvent {
  const VoiceTurnInterruptedEvent({
    required this.transcript,
    required this.partialReplyText,
  });
  final String transcript;
  final String partialReplyText;
  @override
  String toString() =>
      'VoiceTurnInterruptedEvent(transcript: "$transcript", partialReplyText: "$partialReplyText")';
}

/// Non-fatal, per-turn error. RESERVED in v1 (never emitted): fatal errors in
/// runTurn surface as Dart stream errors. Exists so future full-duplex mode can
/// report a per-turn failure without tearing down the stream (§4.1 E1).
class VoiceErrorEvent extends VoiceEvent {
  const VoiceErrorEvent(this.error, {this.stackTrace});
  final Object error;
  final StackTrace? stackTrace;
  @override
  String toString() => 'VoiceErrorEvent($error)';
}

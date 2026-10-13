import 'dart:typed_data';

/// The LLM step of a voice turn: stream the reply's tokens for a user utterance,
/// plus a portable stop for barge-in. Injecting this (not a concrete type) keeps
/// [VoiceSession] engine-agnostic and usable with a chat, an agent, or a custom
/// (remote / one-shot) responder. (Design spec §4.2.)
class VoiceResponder {
  const VoiceResponder({
    required this.respond,
    required this.stop,
    this.respondToAudio,
  });

  /// Stream the reply's tokens for [userText].
  final Stream<String> Function(String userText) respond;

  /// Stream the reply's tokens for the recording itself, with no
  /// speech-to-text: for a model that hears audio (Gemma 4 E2B or E4B, created
  /// with `supportAudio: true`). It receives what [VoiceSession.runAudioTurn]
  /// received — 16 kHz mono 16-bit LE PCM, bare samples — and a responder that
  /// sends it to a `.litertlm` chat wraps it in a WAV header first, since
  /// LiteRT-LM decodes an audio file (`VoiceSession.fromChat` does that).
  ///
  /// Optional: without it, [VoiceSession.runAudioTurn] throws [StateError].
  final Stream<String> Function(Uint8List pcm16kMono)? respondToAudio;

  /// Portable stop of in-flight generation (e.g. `chat.stopGeneration`).
  ///
  /// CONTRACT: stop() must cause the [respond] stream to terminate promptly.
  /// [VoiceSession.interrupt] drains with a timeout, so a stop() that does not
  /// end the stream will not hang the session — but it defers the interrupt and
  /// leaves generation running in the background. stop() MAY throw; interrupt()
  /// catches and proceeds to the bounded drain regardless.
  final Future<void> Function() stop;
}

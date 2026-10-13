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
  /// with `supportAudio: true`). It receives the recording
  /// [VoiceSession.runAudioTurn] got as a WAV file — its 16 kHz mono 16-bit
  /// PCM behind a 44-byte RIFF header — which is what a `.litertlm` chat
  /// decodes: pass it on as is, e.g. to `Message.withAudio` or to an agent's
  /// `ask('', audioBytes: wav)`.
  ///
  /// Optional: without it, [VoiceSession.runAudioTurn] throws [StateError].
  final Stream<String> Function(Uint8List wav)? respondToAudio;

  /// Portable stop of in-flight generation (e.g. `chat.stopGeneration`).
  ///
  /// CONTRACT: stop() must cause the in-flight [respond] or [respondToAudio]
  /// stream to terminate promptly.
  /// [VoiceSession.interrupt] drains with a timeout, so a stop() that does not
  /// end the stream will not hang the session — but it defers the interrupt and
  /// leaves generation running in the background. stop() MAY throw; interrupt()
  /// catches and proceeds to the bounded drain regardless.
  final Future<void> Function() stop;
}

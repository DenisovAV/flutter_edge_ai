// Streaming speech: the capability interfaces a recognizer or synthesizer
// implements when it can work on audio or text as it arrives. Separate from
// SpeechRecognizer / SpeechSynthesizer on purpose: those are open abstract
// classes that apps, tests and third-party backends implement, and a member
// added to them would break every implementer. A backend implements these as
// well when its model can stream; an app finds out with `asStreaming`.
library;

import 'dart:typed_data';

import 'interface.dart' show SpeechRecognizer, SpeechSynthesizer;

/// A [SpeechRecognizer] that transcribes audio as it arrives.
///
/// Get one with [SpeechRecognizerStreaming.asStreaming] on the recognizer
/// `FlutterEdgeAi.getActiveStt` returns; it is null when the active model
/// cannot stream.
abstract interface class StreamingSpeechRecognizer implements SpeechRecognizer {
  /// Transcribes [pcm16kMono], 16 kHz mono 16-bit little-endian PCM in chunks
  /// of any size, as it arrives.
  ///
  /// - One stream runs at a time per recognizer; calling this while one runs
  ///   throws [StateError]. `transcribe` calls are refused meanwhile, the same
  ///   way.
  /// - Audio not yet analysed is held up to
  ///   [TranscribeStreamOptions.maxBufferedAudio]; past it the stream ends
  ///   with a [SpeechStreamOverrunException]. Audio is never dropped
  ///   silently.
  /// - [language] (Whisper only, as in `transcribe`) is read once, when the
  ///   stream starts.
  /// - The stream ends after the input ends and the last update is out (with
  ///   [TranscriptUpdate.endpoint] true). An input error ends it with that
  ///   error; closing the recognizer, or its worker ending, ends it with a
  ///   [StateError], never a silent done.
  /// - Cancelling the subscription stops reading the input and emitting at
  ///   once. A window already running in native code finishes and its result
  ///   is dropped.
  Stream<TranscriptUpdate> transcribeStream(
    Stream<Uint8List> pcm16kMono, {
    String? language,
    TranscribeStreamOptions options = const TranscribeStreamOptions(),
  });

  /// Finalises what the running stream has heard so far without ending its
  /// input: the next update confirms all of it and has
  /// [TranscriptUpdate.endpoint] true. For a voice activity detector's end of
  /// utterance. Completes when that update has been emitted; throws
  /// [StateError] when no stream runs.
  Future<void> flush();

  /// How this model streams.
  StreamingSttInfo get streaming;
}

/// What a streaming recognizer knows after it has analysed more audio: text
/// that will not change any more, and a tail that may.
final class TranscriptUpdate {
  const TranscriptUpdate({
    required this.confirmedDelta,
    required this.unconfirmed,
    required this.confirmedUntil,
    this.confirmedWords = const [],
    this.endpoint = false,
  });

  /// Text confirmed since the previous update, to append to the confirmed
  /// transcript (with its leading space, if any). Often empty.
  final String confirmedDelta;

  /// The text heard after the confirmed transcript, which later audio may
  /// still change. Replaces the previous update's [unconfirmed].
  final String unconfirmed;

  /// Audio time, from the stream's first sample, up to which the transcript
  /// is confirmed.
  final Duration confirmedUntil;

  /// The words of [confirmedDelta] with their positions; empty when the model
  /// gives none.
  final List<WordTiming> confirmedWords;

  /// Whether this update closes an utterance: the input ended, or [flush] was
  /// called. [unconfirmed] is then empty.
  final bool endpoint;

  @override
  String toString() =>
      'TranscriptUpdate(+"$confirmedDelta", ~"$unconfirmed", '
      'until $confirmedUntil${endpoint ? ', endpoint' : ''})';
}

/// How far behind the audio a windowed recognizer may run.
enum StreamingLatency {
  /// Windows overlap by three quarters: text is confirmed about 1-2 s after
  /// it is spoken, for four times the work of a batch transcription.
  lowLatency,

  /// Windows overlap by half: confirmed later, for twice the work.
  balanced,
}

/// Options of [StreamingSpeechRecognizer.transcribeStream].
final class TranscribeStreamOptions {
  const TranscribeStreamOptions({
    this.latency = StreamingLatency.lowLatency,
    this.maxBufferedAudio = const Duration(seconds: 10),
  });

  /// For a windowed model; an incremental one ignores it.
  final StreamingLatency latency;

  /// The most audio held before it is analysed; past it the stream fails
  /// with a [SpeechStreamOverrunException].
  final Duration maxBufferedAudio;
}

/// How a streaming recognizer's model works.
enum StreamingKind {
  /// It re-reads overlapping windows of a fixed length, so text near the
  /// newest audio can still change ([TranscriptUpdate.unconfirmed]).
  windowed,

  /// It reads each chunk once and carries its state, so text it emits is
  /// final as soon as it is emitted.
  incremental,
}

/// What [StreamingSpeechRecognizer.streaming] reports.
final class StreamingSttInfo {
  const StreamingSttInfo({required this.kind, required this.window});

  final StreamingKind kind;

  /// The audio one model run reads: the window of a windowed model, the
  /// chunk of an incremental one.
  final Duration window;
}

/// The audio given to [StreamingSpeechRecognizer.transcribeStream] got more
/// than [TranscribeStreamOptions.maxBufferedAudio] ahead of the model.
final class SpeechStreamOverrunException implements Exception {
  const SpeechStreamOverrunException(this.buffered, this.limit);

  final Duration buffered;
  final Duration limit;

  @override
  String toString() =>
      'SpeechStreamOverrunException: $buffered of audio waiting for the '
      'model, over the $limit limit; the model runs slower than the audio '
      'arrives on this device';
}

/// A [SpeechSynthesizer] that produces audio chunk by chunk, and can take its
/// text in pieces.
///
/// Get one with [SpeechSynthesizerStreaming.asStreaming] on the synthesizer
/// `FlutterEdgeAi.getActiveTts` returns.
abstract interface class StreamingSpeechSynthesizer
    implements SpeechSynthesizer {
  /// The audio for [text], one [SpeechChunk] at a time as each is
  /// synthesized.
  ///
  /// One stream ([synthesizeStream] or [openTextStream]) runs at a time per
  /// synthesizer; another call throws [StateError], as does `synthesize`
  /// meanwhile. The stream is single-subscription and synthesis runs only a
  /// few chunks ahead of its listener. Cancelling the subscription stops
  /// synthesis at the next step boundary; closing the synthesizer ends the
  /// stream with a [StateError].
  Stream<SpeechChunk> synthesizeStream(String text);

  /// A stream that takes its text in pieces, such as a language model's
  /// tokens, and speaks it as soon as a phrase is complete.
  SpeechTextStream openTextStream();
}

/// One piece of synthesized audio.
final class SpeechChunk {
  const SpeechChunk({
    required this.pcm,
    required this.sampleRate,
    required this.index,
    this.words = const [],
  });

  /// 16-bit little-endian mono PCM at [sampleRate], as `synthesize` returns.
  final Uint8List pcm;

  final int sampleRate;

  /// 0 for the first chunk of a stream, then 1, 2, …
  final int index;

  /// The words whose audio starts in this chunk; empty when the model gives
  /// no timings.
  final List<WordTiming> words;
}

/// Text in, [audio] out: what [StreamingSpeechSynthesizer.openTextStream]
/// returns.
abstract interface class SpeechTextStream {
  /// Appends [delta] to the text. Throws [StateError] after [close] or
  /// [cancel].
  void add(String delta);

  /// No more text: what is left is spoken and [audio] ends.
  Future<void> close();

  /// The audio, single-subscription, a few chunks ahead of its listener at
  /// most.
  Stream<SpeechChunk> get audio;

  /// Drops the text not yet spoken and the audio not yet delivered (a
  /// barge-in). Completes when synthesis has stopped; [audio] then ends
  /// without an error.
  Future<void> cancel();
}

/// Where a word is, in text and in audio.
///
/// [start] and [end] are UTF-16 indices into the caller's text: for speech-
/// to-text the transcript, for text-to-speech everything given to the stream
/// so far. [audioStart] and [audioEnd] count from the stream's first sample,
/// pauses included.
final class WordTiming {
  const WordTiming({
    required this.word,
    required this.start,
    required this.end,
    required this.audioStart,
    required this.audioEnd,
  });

  final String word;
  final int start;
  final int end;
  final Duration audioStart;
  final Duration audioEnd;

  @override
  bool operator ==(Object other) =>
      other is WordTiming &&
      other.word == word &&
      other.start == start &&
      other.end == end &&
      other.audioStart == audioStart &&
      other.audioEnd == audioEnd;

  @override
  int get hashCode => Object.hash(word, start, end, audioStart, audioEnd);

  @override
  String toString() => 'WordTiming("$word" $start-$end, $audioStart-$audioEnd)';
}

/// Finds the streaming side of a recognizer.
extension SpeechRecognizerStreaming on SpeechRecognizer {
  /// This recognizer as a [StreamingSpeechRecognizer], or null when its model
  /// cannot stream.
  StreamingSpeechRecognizer? get asStreaming {
    final self = this;
    return self is StreamingSpeechRecognizer ? self : null;
  }
}

/// Finds the streaming side of a synthesizer.
extension SpeechSynthesizerStreaming on SpeechSynthesizer {
  /// This synthesizer as a [StreamingSpeechSynthesizer], or null when its
  /// model cannot stream.
  StreamingSpeechSynthesizer? get asStreaming {
    final self = this;
    return self is StreamingSpeechSynthesizer ? self : null;
  }
}

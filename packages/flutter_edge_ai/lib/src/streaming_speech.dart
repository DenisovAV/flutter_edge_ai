// Streaming speech: the capability interfaces a recognizer or synthesizer
// implements when it can work on audio or text as it arrives. Separate from
// SpeechRecognizer / SpeechSynthesizer on purpose: those are open abstract
// classes that apps, tests and third-party backends implement, and a member
// added to them would break every implementer. A backend implements these as
// well when its model can stream; an app finds out with `asStreaming`.
//
// These are experimental: core may add members to the two interfaces in a
// minor release, so a backend that implements them pins core to a minor
// version range. Apps only call them, which no such addition breaks.
library;

import 'dart:typed_data';

import 'package:meta/meta.dart' show experimental;

import 'interface.dart' show SpeechRecognizer, SpeechSynthesizer;

/// A [SpeechRecognizer] that transcribes audio as it arrives.
///
/// Get one with [SpeechRecognizerStreaming.asStreaming] on the recognizer
/// `FlutterEdgeAi.getActiveStt` returns; it is null when the active model
/// cannot stream.
///
/// Experimental: core may add members in a minor release. Implement it only
/// in a backend that pins core to a minor version range.
@experimental
abstract interface class StreamingSpeechRecognizer implements SpeechRecognizer {
  /// Transcribes [pcm16kMono], 16 kHz mono 16-bit little-endian PCM in chunks
  /// of any size, as it arrives.
  ///
  /// - One stream runs at a time per recognizer. The stream claims the
  ///   recognizer when it is listened to, not when this is called, so a
  ///   stream nobody listens to holds nothing. If another stream holds it
  ///   then, or the recognizer is closed, the stream ends at once with a
  ///   [StateError]. The claim is released when the stream is done, ends
  ///   with an error, or when the future of its subscription's `cancel`
  ///   completes.
  /// - [language] (Whisper only, as in `transcribe`) is checked and read when
  ///   the stream is listened to; later changes to the recognizer's language
  ///   do not affect it.
  /// - `transcribe` calls made while a stream runs are not refused: they
  ///   wait their turn on the same model, between two windows of the stream.
  /// - Audio received but not analysed yet is held up to
  ///   [TranscribeStreamOptions.maxBufferedAudio]; past it the stream ends
  ///   with a [SpeechStreamOverrunException]. Audio is never dropped
  ///   silently. Pausing this stream does not pause reading [pcm16kMono].
  /// - The stream ends after the input ends and the last update is out, with
  ///   [TranscriptUpdate.endpoint] true. An input error ends it with that
  ///   error. Closing the recognizer, or its worker ending, stops reading the
  ///   input and ends the stream with a [StateError], never a silent done.
  /// - Cancelling the subscription cancels the input and stops emitting at
  ///   once; a model run already in native code finishes, its result is
  ///   dropped, and the cancel future completes after it.
  ///
  /// Throws [ArgumentError] for [options] that cannot work (see
  /// [TranscribeStreamOptions]).
  Stream<TranscriptUpdate> transcribeStream(
    Stream<Uint8List> pcm16kMono, {
    String? language,
    TranscribeStreamOptions options = const TranscribeStreamOptions(),
  });

  /// Finalises what the running stream has received so far, without ending
  /// its input; for a voice activity detector's end of utterance.
  ///
  /// The first update that covers all audio received before this call
  /// confirms all of it and has [TranscriptUpdate.endpoint] true; with no
  /// new audio since the last update, that is an update with empty texts.
  /// Completes after that update has been emitted. Calls made before it
  /// completes share it. Throws [StateError] when no stream runs (including
  /// after the running stream's input has ended).
  Future<void> flush();

  /// How this model streams.
  StreamingSttInfo get streaming;
}

/// What a streaming recognizer knows after it has analysed more audio: text
/// that will not change any more, and a tail that may.
@experimental
final class TranscriptUpdate {
  TranscriptUpdate({
    required this.confirmedDelta,
    required this.unconfirmed,
    required this.confirmedUntil,
    List<WordTiming> confirmedWords = const [],
    this.endpoint = false,
  }) : confirmedWords = List.unmodifiable(confirmedWords);

  /// Text confirmed since the previous update, to append to the confirmed
  /// transcript (with its leading space, if any). Often empty.
  final String confirmedDelta;

  /// The text heard after the confirmed transcript, which later audio may
  /// still change. Replaces the previous update's [unconfirmed].
  final String unconfirmed;

  /// Audio time, from the stream's first sample, before which every word
  /// spoken is in the confirmed transcript. A lower bound: a model that
  /// aligns its windows by text rather than time may confirm words spoken
  /// after it.
  final Duration confirmedUntil;

  /// The words of [confirmedDelta] with their positions, indices into the
  /// confirmed transcript (all [confirmedDelta]s concatenated); empty when
  /// the model gives none. A word appears once, in the update that confirms
  /// it.
  final List<WordTiming> confirmedWords;

  /// Whether this update closes an utterance: the input ended, or
  /// [StreamingSpeechRecognizer.flush] was called. [unconfirmed] is then
  /// empty.
  final bool endpoint;

  @override
  bool operator ==(Object other) =>
      other is TranscriptUpdate &&
      other.confirmedDelta == confirmedDelta &&
      other.unconfirmed == unconfirmed &&
      other.confirmedUntil == confirmedUntil &&
      other.endpoint == endpoint &&
      _listEquals(other.confirmedWords, confirmedWords);

  @override
  int get hashCode => Object.hash(
    confirmedDelta,
    unconfirmed,
    confirmedUntil,
    endpoint,
    Object.hashAll(confirmedWords),
  );

  @override
  String toString() =>
      'TranscriptUpdate(+"$confirmedDelta", ~"$unconfirmed", '
      'until $confirmedUntil${endpoint ? ', endpoint' : ''})';
}

/// How far behind the audio a windowed recognizer may run. The window
/// length is the model's ([StreamingSttInfo.window]); the overlap decides
/// how often a window runs and how soon text is confirmed.
@experimental
enum StreamingLatency {
  /// Windows overlap by three quarters: a window runs every quarter window
  /// of audio (1.25 s for a 5 s window), four times the work of a batch
  /// transcription.
  lowLatency,

  /// Windows overlap by half: a window runs every half window, twice the
  /// work.
  balanced,
}

/// Options of [StreamingSpeechRecognizer.transcribeStream].
@experimental
final class TranscribeStreamOptions {
  const TranscribeStreamOptions({
    this.latency = StreamingLatency.lowLatency,
    this.maxBufferedAudio = const Duration(seconds: 10),
  });

  /// For a windowed model; an incremental one ignores it.
  final StreamingLatency latency;

  /// The most audio received but not analysed yet (the overlap a windowed
  /// model keeps on purpose does not count); past it the stream fails with
  /// a [SpeechStreamOverrunException]. Must be at least the model's
  /// [StreamingSttInfo.window], or `transcribeStream` throws
  /// [ArgumentError].
  final Duration maxBufferedAudio;

  @override
  bool operator ==(Object other) =>
      other is TranscribeStreamOptions &&
      other.latency == latency &&
      other.maxBufferedAudio == maxBufferedAudio;

  @override
  int get hashCode => Object.hash(latency, maxBufferedAudio);
}

/// How a streaming recognizer's model works.
@experimental
enum StreamingKind {
  /// It re-reads overlapping windows of a fixed length, so text near the
  /// newest audio can still change ([TranscriptUpdate.unconfirmed]).
  windowed,

  /// It reads each chunk once and carries its state, so text it emits is
  /// final as soon as it is emitted.
  incremental,
}

/// What [StreamingSpeechRecognizer.streaming] reports.
@experimental
final class StreamingSttInfo {
  const StreamingSttInfo({required this.kind, required this.window});

  final StreamingKind kind;

  /// The audio one model run reads: the window of a windowed model, the
  /// chunk of an incremental one.
  final Duration window;

  @override
  bool operator ==(Object other) =>
      other is StreamingSttInfo && other.kind == kind && other.window == window;

  @override
  int get hashCode => Object.hash(kind, window);

  @override
  String toString() => 'StreamingSttInfo(${kind.name}, $window)';
}

/// The audio given to [StreamingSpeechRecognizer.transcribeStream] got more
/// than [TranscribeStreamOptions.maxBufferedAudio] ahead of the model.
@experimental
final class SpeechStreamOverrunException implements Exception {
  const SpeechStreamOverrunException({
    required this.buffered,
    required this.limit,
  });

  /// Audio received and not analysed when the stream failed.
  final Duration buffered;

  /// [TranscribeStreamOptions.maxBufferedAudio].
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
///
/// Experimental: core may add members in a minor release. Implement it only
/// in a backend that pins core to a minor version range.
@experimental
abstract interface class StreamingSpeechSynthesizer
    implements SpeechSynthesizer {
  /// The audio for [text], one [SpeechChunk] at a time as each is
  /// synthesized.
  ///
  /// One stream ([synthesizeStream] or [openTextStream]) holds the
  /// synthesizer at a time. This stream claims it when it is listened to; if
  /// another holds it then, or the synthesizer is closed, it ends at once
  /// with a [StateError]. The claim is released when the stream is done,
  /// ends with an error, or when its cancel future completes. `synthesize`
  /// calls made meanwhile wait their turn on the same model.
  ///
  /// The stream is single-subscription and synthesis runs only a few chunks
  /// ahead of its listener. Cancelling the subscription stops synthesis at
  /// the next step boundary; the cancel future completes when it has
  /// stopped. A synthesis failure ends the stream with its error; closing the
  /// synthesizer ends it with a [StateError].
  Stream<SpeechChunk> synthesizeStream(String text);

  /// A stream that takes its text in pieces, such as a language model's
  /// tokens, and speaks each phrase as soon as it is complete.
  ///
  /// The returned stream claims the synthesizer at once: this throws
  /// [StateError] if another stream holds it or the synthesizer is closed.
  /// The claim is released when [SpeechTextStream.audio] is done or ends
  /// with an error, or when [SpeechTextStream.cancel] (or the cancel of
  /// [SpeechTextStream.audio]'s subscription) completes.
  SpeechTextStream openTextStream();
}

/// One piece of synthesized audio.
@experimental
final class SpeechChunk {
  SpeechChunk({
    required this.pcm,
    required this.sampleRate,
    required this.index,
    List<WordTiming> words = const [],
  }) : words = List.unmodifiable(words);

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
@experimental
abstract interface class SpeechTextStream {
  /// Appends [delta] to the text. Throws [StateError] after [close] or
  /// [cancel], or once [audio] has ended.
  void add(String delta);

  /// No more text: what is left is spoken and [audio] ends. Completes when
  /// [audio] is done, so it waits for a listener to drain [audio]; a
  /// synthesis failure completes it with that error. Calling it again
  /// returns the same future.
  Future<void> close();

  /// The audio, single-subscription, a few chunks ahead of its listener at
  /// most. A synthesis failure ends it with that error; closing the
  /// synthesizer ends it with a [StateError]. Cancelling its subscription
  /// is a [cancel]: the text not yet spoken is dropped, the claim is
  /// released, and the subscription's cancel future completes when
  /// synthesis has stopped.
  Stream<SpeechChunk> get audio;

  /// Drops the text not yet spoken and the audio not yet delivered (a
  /// barge-in), whether or not [audio] has a listener. Completes when
  /// synthesis has stopped; [audio] then ends without an error. Calling it
  /// again, or after [audio] has ended, returns the same future.
  Future<void> cancel();
}

/// Where a word is, in text and in audio.
///
/// [word] is the text as written where it comes from: the transcript for
/// speech-to-text, the caller's text for text-to-speech (`42`, not the
/// `forty two` that is spoken). [start] and [end] are UTF-16 indices into
/// that text: for speech-to-text the confirmed transcript, for
/// text-to-speech everything given to the stream so far. [audioStart] and
/// [audioEnd] count from the stream's first sample, pauses included.
@experimental
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
@experimental
extension SpeechRecognizerStreaming on SpeechRecognizer {
  /// This recognizer as a [StreamingSpeechRecognizer], or null when its model
  /// cannot stream.
  StreamingSpeechRecognizer? get asStreaming {
    final self = this;
    return self is StreamingSpeechRecognizer ? self : null;
  }
}

/// Finds the streaming side of a synthesizer.
@experimental
extension SpeechSynthesizerStreaming on SpeechSynthesizer {
  /// This synthesizer as a [StreamingSpeechSynthesizer], or null when its
  /// model cannot stream.
  StreamingSpeechSynthesizer? get asStreaming {
    final self = this;
    return self is StreamingSpeechSynthesizer ? self : null;
  }
}

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

// Streaming speech: the value types of `SpeechRecognizer.transcribeStream`,
// `SpeechSynthesizer.synthesizeStream` and `SpeechSynthesizer.openTextStream`
// (those members are in interface.dart, on the two classes themselves).
//
// Core may add members to the speech classes in a minor release, each with a
// default body (a class that extends them inherits it; one that implements
// them adds it), and fields to these types. Values may be added to the enums
// too: a `switch` over one that lists every value then needs the new case.
library;

import 'dart:typed_data';

import 'interface.dart' show SpeechRecognizer, SpeechSynthesizer;

/// What a streaming recognizer knows after it has analysed more audio: text
/// that will not change any more, and a tail that may.
final class TranscriptUpdate {
  TranscriptUpdate({
    required this.confirmedDelta,
    required this.unconfirmed,
    required this.confirmedUntil,
    List<WordTiming> confirmedWords = const [],
    this.endpoint = false,
  }) : assert(
         !endpoint || unconfirmed == '',
         'an endpoint update has no unconfirmed text',
       ),
       assert(
         !confirmedUntil.isNegative,
         'confirmedUntil counts from the stream start',
       ),
       confirmedWords = List.unmodifiable(confirmedWords);

  /// Text confirmed since the previous update, to append to the confirmed
  /// transcript (with its leading space, if any). Often empty. The confirmed
  /// transcript is the whole stream's: a flush does not start it over.
  final String confirmedDelta;

  /// The text heard after the confirmed transcript, which later audio may
  /// still change. Replaces the previous update's [unconfirmed]. Always
  /// empty from an incremental model ([StreamingKind.incremental]).
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

  /// Whether this update closes an utterance: the input ended,
  /// [SpeechRecognizer.flush] was called, or a model that detects the end of
  /// an utterance itself did so. [unconfirmed] is then empty.
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
      'until $confirmedUntil, ${confirmedWords.length} words'
      '${endpoint ? ', endpoint' : ''})';
}

/// How far behind the audio a windowed recognizer may run. The window
/// length is the model's ([StreamingSttInfo.window]); the overlap decides
/// how often a window runs and how soon text is confirmed.
///
/// Values may be added in a minor release: a `switch` that lists every value
/// then needs the new case.
enum StreamingLatency {
  /// Windows overlap by three quarters: a window runs every quarter window
  /// of audio (1.25 s for a 5 s window), four times the work of a batch
  /// transcription. The default: it confirms text twice as often as
  /// [balanced], and Parakeet CTC int8 transcribed LibriSpeech test-clean
  /// about as accurately either way (the speech package's README has the
  /// numbers).
  lowLatency,

  /// Windows overlap by half: a window runs every half window, twice the
  /// work.
  balanced,
}

/// Options of [SpeechRecognizer.transcribeStream].
final class TranscribeStreamOptions {
  const TranscribeStreamOptions({
    this.latency = StreamingLatency.lowLatency,
    this.maxBufferedAudio,
  });

  /// How often a windowed model runs a window. An incremental model may map
  /// it to its chunk size, or ignore it.
  final StreamingLatency latency;

  /// The most audio received but not analysed yet (the overlap a windowed
  /// model keeps on purpose does not count); past it the stream fails with
  /// a [SpeechStreamOverrunException]. Null, the default, is 10 s, or the
  /// model's [StreamingSttInfo.window] when that is longer. A value must be
  /// at least that window, or `transcribeStream` throws [ArgumentError].
  final Duration? maxBufferedAudio;

  /// [maxBufferedAudio] for a model whose window is [window], the default
  /// applied. Throws [ArgumentError] for a set value shorter than [window]:
  /// the check `transcribeStream` makes on a model that streams (one that
  /// cannot never checks the options).
  Duration maxBufferedAudioFor(Duration window) {
    final set = maxBufferedAudio;
    if (set != null) {
      if (set < window) {
        throw ArgumentError.value(
          set,
          'options.maxBufferedAudio',
          'must be at least the model window, $window',
        );
      }
      return set;
    }
    const fallback = Duration(seconds: 10);
    return window > fallback ? window : fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is TranscribeStreamOptions &&
      other.latency == latency &&
      other.maxBufferedAudio == maxBufferedAudio;

  @override
  int get hashCode => Object.hash(latency, maxBufferedAudio);

  @override
  String toString() =>
      'TranscribeStreamOptions(${latency.name}, '
      'maxBufferedAudio: ${maxBufferedAudio ?? 'default'})';
}

/// How a streaming recognizer's model works.
///
/// Values may be added in a minor release: a `switch` that lists every value
/// then needs the new case.
enum StreamingKind {
  /// It re-reads overlapping windows of a fixed length, so text near the
  /// newest audio can still change ([TranscriptUpdate.unconfirmed]).
  windowed,

  /// It reads each chunk once and carries its state, so text it emits is
  /// final as soon as it is emitted.
  incremental,
}

/// What [SpeechRecognizer.streaming] reports.
final class StreamingSttInfo {
  // Not const: a const constructor cannot check a Duration.
  StreamingSttInfo({required this.kind, required this.window})
    : assert(window > Duration.zero, 'a window holds some audio');

  final StreamingKind kind;

  /// The audio one model run reads: the window of a windowed model, the
  /// chunk of an incremental one. Longer than zero.
  final Duration window;

  @override
  bool operator ==(Object other) =>
      other is StreamingSttInfo && other.kind == kind && other.window == window;

  @override
  int get hashCode => Object.hash(kind, window);

  @override
  String toString() => 'StreamingSttInfo(${kind.name}, $window)';
}

/// The audio given to [SpeechRecognizer.transcribeStream] got more
/// than [TranscribeStreamOptions.maxBufferedAudio] ahead of the model.
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
      'model, over the $limit limit: the model runs slower than the audio '
      'arrives on this device, or a transcribe() call held it that long. '
      'StreamingLatency.balanced halves the work of a windowed model';
}

/// One piece of synthesized audio.
final class SpeechChunk {
  SpeechChunk({
    required this.pcm,
    required this.sampleRate,
    required this.index,
    List<WordTiming> words = const [],
  }) : assert(sampleRate > 0, 'sampleRate must be positive'),
       assert(index >= 0, 'index counts from 0'),
       assert(pcm.lengthInBytes.isEven, 'pcm holds whole 16-bit samples'),
       words = List.unmodifiable(words);

  /// 16-bit little-endian mono PCM at [sampleRate], as `synthesize` returns.
  /// Not copied: the synthesizer does not touch it again, and a listener
  /// must not change it.
  final Uint8List pcm;

  /// The synthesizer's `SpeechSynthesizer.sampleRate`.
  final int sampleRate;

  /// 0 for the first chunk of a stream, then 1, 2, …
  final int index;

  // No == / hashCode on purpose: pcm is a large buffer that is not copied,
  // and comparing it by identity would mislead.

  /// The words whose audio starts in this chunk; empty when the model gives
  /// no timings.
  final List<WordTiming> words;

  @override
  String toString() =>
      'SpeechChunk(#$index, ${pcm.lengthInBytes ~/ 2} samples at '
      '$sampleRate Hz, ${words.length} words)';
}

/// Text in, [audio] out: what [SpeechSynthesizer.openTextStream]
/// returns.
abstract interface class SpeechTextStream {
  /// Appends [delta] to the text. Throws [StateError] after [close] or
  /// [cancel], or once [audio] has ended.
  void add(String delta);

  /// No more text: what is left is spoken and [audio] ends. Completes when
  /// [audio] is done, so **it never completes while nobody listens to
  /// [audio]**: listen first, or do not await it. A synthesis failure
  /// completes it with that error. Calling it again returns the same
  /// future; after [cancel] it returns [cancel]'s future.
  Future<void> close();

  /// The audio, single-subscription, a few chunks ahead of its listener at
  /// most. A synthesis failure ends it with that error; closing the
  /// synthesizer ends it with a [StateError]. Cancelling its subscription
  /// is a [cancel]: the text not yet spoken is dropped, the claim is
  /// released, and the subscription's cancel future completes when
  /// synthesis has stopped.
  Stream<SpeechChunk> get audio;

  /// Drops the text not yet spoken and the audio not yet delivered (a
  /// barge-in; chunks the app has already handed to its player keep playing
  /// until it stops the player), whether or not [audio] has a listener. Synthesis stops at
  /// the next step boundary (the step in flight finishes, its audio is
  /// dropped); this completes when it has stopped, and [audio] then ends
  /// without an error. Calling it again, or after [audio] has ended,
  /// returns the same future.
  Future<void> cancel();
}

/// Where a word is, in text and in audio.
///
/// [word] is the text as written where it comes from: the transcript for
/// speech-to-text, the caller's text for text-to-speech (`42`, not the
/// `forty two` that is spoken). [start] and [end] are UTF-16 indices into
/// that text, half-open (`text.substring(start, end) == word`): for
/// speech-to-text the confirmed transcript of the whole stream (a flush
/// does not start it over), for text-to-speech everything given to the
/// stream so far. [audioStart] and [audioEnd] (half-open too, `audioStart <=
/// audioEnd`) count from the stream's first sample, pauses included.
final class WordTiming {
  // Not const: a const constructor cannot check a Duration.
  WordTiming({
    required this.word,
    required this.start,
    required this.end,
    required this.audioStart,
    required this.audioEnd,
  }) : assert(word.isNotEmpty, 'a word has some text'),
       assert(start >= 0 && start <= end, 'start and end index the text'),
       assert(end - start == word.length, 'word is the text start..end'),
       assert(
         !audioStart.isNegative && audioStart <= audioEnd,
         'audio times count from the stream start, the end after the start',
       );

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

bool _listEquals<T>(List<T> a, List<T> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

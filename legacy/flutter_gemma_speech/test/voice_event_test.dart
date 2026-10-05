import 'dart:typed_data';

import 'package:flutter_gemma_speech/src/voice/voice_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('subtypes carry their fields', () {
    expect(const VoiceTranscriptEvent('hi', isFinal: true).text, 'hi');
    expect(const VoiceTranscriptEvent('hi', isFinal: true).isFinal, isTrue);
    expect(const VoiceReplyTextEvent('tok').chunk, 'tok');

    final audio = VoiceReplyAudioEvent(
      Uint8List.fromList([1, 2, 3]),
      sampleRate: 22050,
      isFinal: true,
    );
    expect(audio.pcm, [1, 2, 3]);
    expect(audio.sampleRate, 22050);
    expect(audio.isFinal, isTrue);

    expect(const VoiceTurnCompleteEvent('u', 'a').transcript, 'u');
    expect(const VoiceTurnCompleteEvent('u', 'a').replyText, 'a');

    const interrupted = VoiceTurnInterruptedEvent(
      transcript: 'u',
      partialReplyText: 'par',
    );
    expect(interrupted.transcript, 'u');
    expect(interrupted.partialReplyText, 'par');

    final err = VoiceErrorEvent('boom');
    expect(err.error, 'boom');
  });

  test('toString is informative', () {
    expect(
      const VoiceTranscriptEvent('hi', isFinal: true).toString(),
      contains('hi'),
    );
    expect(
      const VoiceTurnInterruptedEvent(
        transcript: 'u',
        partialReplyText: 'p',
      ).toString(),
      contains('partialReplyText'),
    );
  });

  test('VoiceEvent is exhaustively switchable (sealed)', () {
    String label(VoiceEvent e) => switch (e) {
      VoiceTranscriptEvent() => 'transcript',
      VoiceReplyTextEvent() => 'replyText',
      VoiceReplyAudioEvent() => 'replyAudio',
      VoiceTurnCompleteEvent() => 'complete',
      VoiceTurnInterruptedEvent() => 'interrupted',
      VoiceErrorEvent() => 'error',
    };
    expect(label(const VoiceTurnCompleteEvent('', '')), 'complete');
  });
}

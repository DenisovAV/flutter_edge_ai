import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('voice API is exported from the barrel', () {
    const responder = VoiceResponder(respond: _noResp, stop: _noStop);
    expect(responder, isA<VoiceResponder>());
    const VoiceEvent e = VoiceTurnCompleteEvent('u', 'a');
    expect(e, isA<VoiceTurnCompleteEvent>());
    expect(const VoiceTranscriptEvent('x', isFinal: true).text, 'x');
  });
}

Stream<String> _noResp(String _) => const Stream.empty();
Future<void> _noStop() async {}

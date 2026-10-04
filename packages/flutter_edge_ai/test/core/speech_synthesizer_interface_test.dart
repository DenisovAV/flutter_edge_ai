import 'dart:typed_data';
import 'package:flutter_edge_ai/flutter_edge_ai_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSynth implements SpeechSynthesizer {
  @override
  int get sampleRate => 22050;
  @override
  Future<Uint8List> synthesize(String text) async => Uint8List(4);
  @override
  void addCloseListener(void Function() listener) {}
  @override
  Future<void> close() async {}
}

void main() {
  test('SpeechSynthesizer exposes synthesize/sampleRate/close', () async {
    final SpeechSynthesizer s = _FakeSynth();
    expect(s.sampleRate, 22050);
    expect(await s.synthesize('hi'), isA<Uint8List>());
    await s.close();
  });
}

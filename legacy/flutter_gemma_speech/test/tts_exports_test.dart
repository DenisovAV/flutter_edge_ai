import 'package:flutter_gemma_speech/flutter_gemma_speech.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LiteRtTtsBackend is exported from the barrel and constructs', () {
    const backend = LiteRtTtsBackend();
    expect(backend.name, isNotEmpty);
    expect(backend.priority, 0);
  });
}

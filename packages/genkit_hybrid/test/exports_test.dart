import 'package:genkit_hybrid/genkit_hybrid.dart';
import 'package:test/test.dart';

void main() {
  test('public API is exported', () {
    expect(kOnDevice, 'onDevice');
    expect(kCloud, 'cloud');
    expect(ModelCapability.vision, isNotNull);
    expect(defineHybridRouter, isNotNull);
  });
}

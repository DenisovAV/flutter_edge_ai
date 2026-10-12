import 'package:flutter_edge_ai/src/model_management/model_specs.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ModelManagementType has a distinct tts member', () {
    expect(ModelManagementType.values, contains(ModelManagementType.tts));
    expect(ModelManagementType.tts, isNot(ModelManagementType.stt));
    expect(ModelManagementType.tts, isNot(ModelManagementType.embedding));
    expect(ModelManagementType.tts, isNot(ModelManagementType.inference));
  });
}

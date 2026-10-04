import 'package:flutter_edge_ai_litertlm/flutter_edge_ai_litertlm.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LiteRtLmEngine identity: name + priority', () {
    const engine = LiteRtLmEngine();
    expect(engine.name, 'LiteRT-LM');
    expect(engine.priority, 0);
  });
}

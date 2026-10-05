// Host-VM identity test for the package's MediaPipeEngine. canHandle/createModel
// against a real spec need a platform channel (pigeon) + a real model, so they
// are validated by the on-device MediaPipe integration gate; this pins the
// engine's identity (name/priority/fileType gate) to catch registration-wiring
// regressions, mirroring the litertlm/embeddings package identity tests.

import 'package:flutter_gemma_mediapipe/flutter_gemma_mediapipe.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('MediaPipeEngine identity: name + priority', () {
    const engine = MediaPipeEngine();
    expect(engine.name, 'MediaPipe');
    expect(engine.priority, 0);
  });
}
